/*
 * Copyright (c) 2013, Facebook, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  * Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 *  * Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 *  * Neither the name Facebook nor the names of its contributors may be used to
 *    endorse or promote products derived from this software without specific
 *    prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "fishhook.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
  #define LINKEDIT_SEGMENT    "__LINKEDIT"
  #define MACHO_HEADER_MAGIC  MH_MAGIC_64
  #define MACHO_HEADER_CIGAM  MH_CIGAM_64
  #define LC_SEGMENT_CMD      LC_SEGMENT_64
  #define segment_command_t   struct segment_command_64
  #define section_t           struct section_64
  #define nlist_t             struct nlist_64
#else
  #define LINKEDIT_SEGMENT    "__LINKEDIT"
  #define MACHO_HEADER_MAGIC  MH_MAGIC
  #define MACHO_HEADER_CIGAM  MH_CIGAM
  #define LC_SEGMENT_CMD      LC_SEGMENT
  #define segment_command_t   struct segment_command
  #define section_t           struct section
  #define nlist_t             struct nlist
#endif

struct rebindings_entry {
  struct rebinding *rebindings;
  size_t rebindings_nel;
  struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              struct rebinding rebindings[],
                              size_t nel) {
  struct rebindings_entry *new_entry =
      (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!new_entry) return -1;

  new_entry->rebindings =
      (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
  if (!new_entry->rebindings) {
    free(new_entry);
    return -1;
  }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  new_entry->rebindings_nel = nel;
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

static vm_prot_t get_protection(void *sectionStart) {
  mach_port_t task = mach_task_self();
  vm_address_t addr = (vm_address_t)sectionStart;
  vm_size_t size = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
  memory_object_name_t objectName;

  kern_return_t kr = vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                  (vm_region_info_64_t)&info, &infoCount,
                                  &objectName);
  if (kr != KERN_SUCCESS) return VM_PROT_READ;

  return info.protection;
}

static void perform_rebing_with_section(
    struct rebindings_entry *rebindings,
    section_t *section,
    intptr_t slide,
    nlist_t *symtab,
    char *strtab,
    uint32_t *indirect_symtab) {

  uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
  void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);

  vm_prot_t oldProtection = VM_PROT_READ;
  vm_size_t trunc_page = (vm_size_t)trunc_page;
  if (sizeof(void*) == 8) {
    trunc_page = 0x1000;
  }

  for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
    uint32_t symtab_index = indirect_symbol_indices[i];
    if (symtab_index == INDIRECT_SYMBOL_ABS ||
        symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
      continue;
    }

    uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    char *symbol_name = strtab + strtab_offset;

    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (size_t j = 0; j < cur->rebindings_nel; j++) {
        if (strlen(symbol_name) > 0 &&
            strcmp(symbol_name, cur->rebindings[j].name) == 0) {

          // Store original
          if (cur->rebindings[j].replaced &&
              *(cur->rebindings[j].replaced) == NULL) {
            *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
          }

          // Make writable and patch
          intptr_t startOfPage = (intptr_t)trunc_page;
          void *pageStart = (void *)(((uintptr_t)indirect_symbol_bindings + i * sizeof(void *)) & ~(startOfPage - 1));

          if (oldProtection != VM_PROT_READ) {
            // Already writable
          } else {
            oldProtection = get_protection(pageStart);
          }

          mprotect(pageStart, trunc_page, PROT_READ | PROT_WRITE);
          indirect_symbol_bindings[i] = cur->rebindings[j].replacement;

          break;
        }
      }
      cur = cur->next;
    }
  }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
  segment_command_t *cur_seg_cmd;
  segment_command_t *linkedit_segment = NULL;
  struct symtab_command *symtab_cmd = NULL;
  struct dysymtab_command *dysymtab_cmd = NULL;

  uintptr_t cur = (uintptr_t)header + sizeof(header->magic) + sizeof(header->cputype) + sizeof(header->cpusubtype) + sizeof(header->filetype) + sizeof(header->ncmds) + sizeof(header->sizeofcmds) + sizeof(header->flags);
  if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
    cur = (uintptr_t)header + sizeof(struct mach_header_64);
  }

  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;

    if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command *)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_SEGMENT_CMD) {
      if (strcmp(cur_seg_cmd->segname, LINKEDIT_SEGMENT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    }
  }

  if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment) return;

  uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;

  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);

  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  cur = (uintptr_t)header + sizeof(header->magic) + sizeof(header->cputype) + sizeof(header->cpusubtype) + sizeof(header->filetype) + sizeof(header->ncmds) + sizeof(header->sizeofcmds) + sizeof(header->flags);
  if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
    cur = (uintptr_t)header + sizeof(struct mach_header_64);
  }

  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_CMD) {
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
        continue;
      }

      section_t *sections = (section_t *)((uintptr_t)cur_seg_cmd +
          sizeof(segment_command_t));

      for (uint32_t j = 0; j < cur_seg_cmd->nsects; j++) {
        section_t *section = &sections[j];

        if (strcmp(section->sectname, "__nl_symbol_ptr") == 0 ||
            strcmp(section->sectname, "__la_symbol_ptr") == 0) {
          perform_rebing_with_section(rebindings, section, slide, symtab,
                                      strtab, indirect_symtab);
        }
      }
    }
  }
}

static void _rebind_symbols_for_image(const struct mach_header *header,
                                       intptr_t slide) {
  rebind_symbols_for_image(_rebindings_head, header, slide);
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int ret = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
  if (ret != 0) return ret;

  // Register the callback for future image loads
  // And process already-loaded images
  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; i++) {
    _rebind_symbols_for_image(_dyld_get_image_header(i),
                               _dyld_get_image_vmaddr_slide(i));
  }

  return 0;
}
