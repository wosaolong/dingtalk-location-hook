#
#  inject.py — Windows 上注入 dylib 到钉钉 IPA 的工具
#  不需要 insert_dylib，纯 Python 实现
#
#  用法：
#     pip install lief
#     python inject.py DingTalk.ipa LocationHook.dylib
#
#  输出：DingTalk_Hooked.ipa
#

import os
import sys
import shutil
import tempfile
import zipfile
import subprocess
from pathlib import Path

def main():
    if len(sys.argv) < 3:
        print("用法: python inject.py <钉钉IPA路径> <dylib路径>")
        print("示例: python inject.py DingTalk.ipa LocationHook.dylib")
        sys.exit(1)

    ipa_path = Path(sys.argv[1])
    dylib_path = Path(sys.argv[2])

    if not ipa_path.exists():
        print(f"❌ 找不到 IPA: {ipa_path}")
        sys.exit(1)
    if not dylib_path.exists():
        print(f"❌ 找不到 dylib: {dylib_path}")
        sys.exit(1)

    # 检查 lief
    try:
        import lief
    except ImportError:
        print("❌ 需要安装 lief 库，执行: pip install lief")
        sys.exit(1)

    print(f"📦 IPA: {ipa_path}")
    print(f"🔧 dylib: {dylib_path}")
    print()

    # 创建临时目录
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        # 1. 解压 IPA
        print("📂 解压 IPA...")
        with zipfile.ZipFile(ipa_path, 'r') as zf:
            zf.extractall(tmp)

        # 找 .app 目录
        payload_dir = tmp / "Payload"
        app_dirs = list(payload_dir.glob("*.app"))
        if not app_dirs:
            print("❌ 找不到 .app 目录，IPA 格式可能不对")
            sys.exit(1)

        app_dir = app_dirs[0]
        print(f"   找到 App: {app_dir.name}")

        # 找主二进制
        binary_name = app_dir.stem  # DingTalk
        binary_path = app_dir / binary_name
        if not binary_path.exists():
            # 尝试找其他可执行文件
            binaries = list(app_dir.glob("*"))
            binaries = [b for b in binaries if b.is_file() and not b.suffix]
            if binaries:
                binary_path = binaries[0]
                print(f"   主二进制: {binary_path.name}")
            else:
                print("❌ 找不到主二进制文件")
                sys.exit(1)

        # 2. 复制 dylib 到 .app 目录
        target_dylib = app_dir / dylib_path.name
        shutil.copy2(dylib_path, target_dylib)
        print(f"✅ dylib 已复制到: {target_dylib.name}")

        # 3. 用 lief 注入 dylib 到主二进制
        print(f"🔧 注入 dylib 到 {binary_path.name}...")
        try:
            binary = lief.parse(str(binary_path))
            if binary is None:
                print("❌ lief 无法解析二进制文件")
                sys.exit(1)

            # 添加 dylib load command
            dylib_name = f"@executable_path/{dylib_path.name}"
            binary.add_library(dylib_name)

            # 写回
            binary.write(str(binary_path))
            print(f"✅ 注入成功: {dylib_name}")

        except Exception as e:
            print(f"❌ 注入失败: {e}")
            sys.exit(1)

        # 4. 重新打包 IPA
        output_ipa = ipa_path.parent / f"{ipa_path.stem}_Hooked.ipa"
        print(f"📦 重新打包 -> {output_ipa.name}...")
        with zipfile.ZipFile(output_ipa, 'w', zipfile.ZIP_DEFLATED) as zf:
            for f in tmp.rglob("*"):
                if f.is_file():
                    arcname = str(f.relative_to(tmp))
                    zf.write(f, arcname)

        print()
        print("=" * 50)
        print(f"🎉 完成！注入版 IPA: {output_ipa}")
        print(f"📱 传到手机用 TrollStore 打开安装")
        print("=" * 50)


if __name__ == "__main__":
    main()
