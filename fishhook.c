/*
 * Copyright (c) 2013, Facebook, Inc.
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *  * Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *  * Neither the name Facebook nor the names of its contributors may be used to
 *    endorse or promote products derived from this software without specific
 *    prior written permission.
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include "fishhook.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

// SEG_DATA_CONST is not always defined in older SDKs
#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST  "__DATA_CONST"
#endif

#ifdef __LP64__
  #define LINKEDIT_SEGMENT    "__LINKEDIT"
  #define segment_command_t   struct segment_command_64
  #define section_t           struct section_64
  #define nlist_t             struct nlist_64
#else
  #define LINKEDIT_SEGMENT    "__LINKEDIT"
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

static int prepend_rebindings(struct rebinding rebindings[], size_t nel) {
  struct rebindings_entry *entry = (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!entry) return -1;
  entry->rebindings = (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
  if (!entry->rebindings) { free(entry); return -1; }
  memcpy(entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  entry->rebindings_nel = nel;
  entry->next = _rebindings_head;
  _rebindings_head = entry;
  return 0;
}

// Calculate page-aligned size for mprotect
static void update_binding(void **bindAddr, void *replacement) {
  // Align down to page boundary
  vm_address_t pageStart = (vm_address_t)bindAddr & ~(vm_page_size - 1);
  mprotect((void *)pageStart, vm_page_size, PROT_READ | PROT_WRITE);
  *bindAddr = replacement;
  mprotect((void *)pageStart, vm_page_size, PROT_READ);
}

static void perform_rebinding_with_section(
    struct rebindings_entry *rebindings,
    section_t *section,
    intptr_t slide,
    nlist_t *symtab,
    char *strtab,
    uint32_t *indirect_symtab) {

  uint32_t *indirect_indices = indirect_symtab + section->reserved1;
  void **bindings = (void **)((uintptr_t)slide + section->addr);

  for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
    uint32_t symIndex = indirect_indices[i];
    if (symIndex == INDIRECT_SYMBOL_ABS ||
        symIndex == INDIRECT_SYMBOL_LOCAL ||
        symIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS))
      continue;

    char *symName = strtab + symtab[symIndex].n_un.n_strx;
    if (strlen(symName) == 0) continue;

    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (size_t j = 0; j < cur->rebindings_nel; j++) {
        if (strcmp(symName, cur->rebindings[j].name) == 0) {
          if (cur->rebindings[j].replaced && *(cur->rebindings[j].replaced) == NULL)
            *(cur->rebindings[j].replaced) = bindings[i];
          update_binding(&bindings[i], cur->rebindings[j].replacement);
          goto next_symbol;
        }
      }
      cur = cur->next;
    }
    next_symbol:;
  }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                      const struct mach_header *header,
                                      intptr_t slide) {
  segment_command_t *cur_seg;
  segment_command_t *linkedit = NULL;
  struct symtab_command *symtab_cmd = NULL;
  struct dysymtab_command *dysymtab_cmd = NULL;

  // Parse load commands
  uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg->cmdsize) {
    cur_seg = (segment_command_t *)cur;
    if (cur_seg->cmd == LC_SYMTAB)
      symtab_cmd = (struct symtab_command *)cur_seg;
    else if (cur_seg->cmd == LC_DYSYMTAB)
      dysymtab_cmd = (struct dysymtab_command *)cur_seg;
    else if (cur_seg->cmd == LC_SEGMENT_64 && strcmp(cur_seg->segname, LINKEDIT_SEGMENT) == 0)
      linkedit = cur_seg;
  }

  if (!symtab_cmd || !dysymtab_cmd || !linkedit) return;

  uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  // Parse sections in __DATA and __DATA_CONST
  cur = (uintptr_t)header + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg->cmdsize) {
    cur_seg = (segment_command_t *)cur;
    if (cur_seg->cmd != LC_SEGMENT_64) continue;
    if (strcmp(cur_seg->segname, "__DATA") != 0 &&
        strcmp(cur_seg->segname, "__DATA_CONST") != 0 &&
        strcmp(cur_seg->segname, "__DATA_DIRTY") != 0)
      continue;

    section_t *sections = (section_t *)((uintptr_t)cur_seg + sizeof(segment_command_t));
    for (uint32_t j = 0; j < cur_seg->nsects; j++) {
      section_t *sect = &sections[j];
      if (strcmp(sect->sectname, "__nl_symbol_ptr") == 0 ||
          strcmp(sect->sectname, "__la_symbol_ptr") == 0) {
        perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
      }
    }
  }
}

static void _rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
  rebind_symbols_for_image(_rebindings_head, header, slide);
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int ret = prepend_rebindings(rebindings, rebindings_nel);
  if (ret != 0) return ret;

  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; i++) {
    _rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
  }
  return 0;
}
