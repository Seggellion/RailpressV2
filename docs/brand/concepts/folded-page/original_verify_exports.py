#!/usr/bin/env python3
"""Reproduce approved SVG exports into a new directory; never overwrite source."""
from pathlib import Path
import argparse,hashlib,json,struct
import gi
gi.require_version('Rsvg','2.0')
from gi.repository import Rsvg

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parents[2]
manifest=json.loads((root/'docs/brand/ASSET_MANIFEST.json').read_text())
for row in manifest['files']:
 path=root/row['path'];assert path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256']
output=args.output.expanduser().absolute();assert not output.exists();output.mkdir(parents=True,mode=0o700)
source=root/'public/brand'/manifest['source'];svg=source.read_text()
assert '<script' not in svg and 'href=' not in svg and '<!ENTITY' not in svg and '<!DOCTYPE' not in svg
exports={}
for size in [16,32,48,180,256]:
 data=svg.replace('width="96" height="96"',f'width="{size}" height="{size}"',1)
 pixbuf=Rsvg.Handle.new_from_data(data.encode()).get_pixbuf()
 assert pixbuf.get_width()==size and pixbuf.get_height()==size and pixbuf.get_has_alpha()
 path=output/f'mark-{size}.png';pixbuf.savev(str(path),'png',[],[])
 data=path.read_bytes();assert struct.unpack('>II',data[16:24])==(size,size) and data[25]==6
 exports[size]=data
offset=54;directory=b'';payload=b''
for size in [16,32,48]:
 data=exports[size];directory+=struct.pack('<BBBBHHII',size,size,0,0,1,32,len(data),offset);payload+=data;offset+=len(data)
ico=struct.pack('<HHH',0,1,3)+directory+payload;(output/'favicon.ico').write_bytes(ico)
assert exports[32]==(root/'public/brand/favicon-9344262c9cd4eab3.png').read_bytes()
assert exports[180]==(root/'public/brand/touch-icon-6e13f7b56aa206a9.png').read_bytes()
assert ico==(root/'public/brand/favicon-da7eff0a98a3fc0a.ico').read_bytes()
print(json.dumps({'status':'PASS','librsvg':f'{Rsvg.MAJOR_VERSION}.{Rsvg.MINOR_VERSION}.{Rsvg.MICRO_VERSION}','PNG_sizes':list(exports),'ICO_sizes':[16,32,48],'reviewed_exports_byte_identical':True,'original_SVG_sha256':hashlib.sha256(source.read_bytes()).hexdigest()}))
