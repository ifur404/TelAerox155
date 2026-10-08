"""Salin hanya sumber aplikasi dan aset publik ke harness sementara, tanpa kredensial."""
from pathlib import Path
import shutil
root=Path(__file__).resolve().parents[3]
out=Path('/private/tmp/telaerox-video-showcase')
for rel in ('TelAerox155.xcodeproj/project.pbxproj','TelAerox155/Info.plist'):
    dest=out/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/rel,dest)
for src in (root/'TelAerox155').rglob('*.swift'):
    dest=out/src.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
shutil.copytree(root/'TelAerox155/Assets.xcassets',out/'TelAerox155/Assets.xcassets',dirs_exist_ok=True)
shutil.copy2(Path(__file__).with_name('ShowcaseApp.swift'),out/'TelAerox155/MyApp.swift')
print(out)
