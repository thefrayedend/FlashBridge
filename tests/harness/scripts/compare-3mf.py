#!/usr/bin/env python3
"""Compares a .gcode.3mf made by FlashBridge with one made by stock OrcaSlicer (the reference the
real printer accepts). Checks the things the printer could care about; prints OK / DIFF lines and
exits 1 if a required item differs.

    python3 -I compare-3mf.py <ours.gcode.3mf> <reference.gcode.3mf>
"""
import hashlib
import re
import sys
import zipfile

ours, ref = (zipfile.ZipFile(p) for p in sys.argv[1:3])
bad = 0


def report(ok, what, detail='', required=True):
    global bad
    print(('OK   ' if ok else ('DIFF ' if required else 'note ')) + what + (f'  ({detail})' if detail and not ok else ''))
    if not ok and required:
        bad += 1


on, rn = set(ours.namelist()), set(ref.namelist())
missing = sorted(rn - on)
report(not missing, 'every entry of the reference is present (incl. plate_no_light / top / pick pictures)', ', '.join(missing))
extra = sorted(on - rn)
report(not extra, 'no entries the reference lacks', ', '.join(extra), required=False)
report(ours.testzip() is None, 'zip CRCs check out')


def gcode(z):
    with z.open('Metadata/plate_1.gcode') as f:
        head = f.read(200000).decode('latin1')
    return head


g, rg = gcode(ours), gcode(ref)
line1 = g.split('\n', 1)[0]
report(re.fullmatch(r'; estimated printing time \(normal mode\) = \d+d \d+h \d+m \d+s', line1) is not None,
       'G-code line 1 is Orca\'s Flashforge print time', line1)
report(g.split('\n')[1] == '; HEADER_BLOCK_START', 'line 2 is ; HEADER_BLOCK_START', g.split('\n')[1])
tb = re.search(r'; HEADER_BLOCK_END\n\n; THUMBNAIL_BLOCK_START\n\n;\n; thumbnail begin (\d+)x(\d+) \d+\n', g)
report(tb is not None, 'thumbnail block right after the header, Orca layout')
if tb:
    report((tb.group(1), tb.group(2)) == ('140', '110'), 'thumbnail is 140x110', f'{tb.group(1)}x{tb.group(2)}')
report('; EXECUTABLE_BLOCK_START' in g, 'EXECUTABLE_BLOCK_START present')

full = ours.read('Metadata/plate_1.gcode')
md5 = ours.read('Metadata/plate_1.gcode.md5').decode().strip()
report(md5 == hashlib.md5(full).hexdigest().upper(), 'md5 file matches the G-code (uppercase hex)')
info = ours.getinfo('3D/3dmodel.model')
report(info.file_size < 100000 and not any(n.startswith('3D/Objects/') for n in on), 'no model mesh inside (like Orca\'s send)')
for n in ('Metadata/plate_1.png', 'Metadata/plate_1_small.png'):
    if n in on:
        report(ours.read(n)[:4] == b'\x89PNG', f'{n} is a PNG')

si, rsi = ours.read('Metadata/slice_info.config').decode(), ref.read('Metadata/slice_info.config').decode()
keys = lambda s: set(re.findall(r'<metadata key="([^"]+)"', s))
report(keys(rsi) <= keys(si), 'slice_info has every metadata key the reference has', ', '.join(sorted(keys(rsi) - keys(si))))
flt = re.search(r'key="first_layer_time" value="([^"]*)"', si)
report(bool(flt and flt.group(1)), 'slice_info first_layer_time filled', 'empty')
ms, rms = ours.read('Metadata/model_settings.config').decode(), ref.read('Metadata/model_settings.config').decode()
report(keys(rms) <= keys(ms), 'model_settings has every key the reference has', ', '.join(sorted(keys(rms) - keys(ms))))
for key in ('thumbnail_file', 'thumbnail_no_light_file', 'top_file', 'pick_file', 'pattern_bbox_file', 'gcode_file'):
    m = re.search(r'key="%s" value="([^"]*)"' % key, ms)
    report(bool(m and m.group(1) in on), f'model_settings {key} points at an entry that exists', m.group(1) if m else 'missing')
# one value per extruder, like Orca writes for a 4-nozzle printer
nozzle_count = len(re.search(r'key="nozzle_diameters" value="([^"]*)"', si).group(1).split(','))
nvt = re.search(r'key="nozzle_volume_type" value="([^"]*)"', si)
report(bool(nvt) and len(nvt.group(1).split()) == nozzle_count, 'slice_info nozzle_volume_type has one value per nozzle', nvt.group(1) if nvt else 'missing')
used_filaments = re.findall(r'<filament id="(\d+)"', si)
fmaps = re.search(r'key="filament_maps" value="([^"]*)"', si)
used_extruders = sorted({fmaps.group(1).split()[int(i) - 1] for i in used_filaments}) if fmaps else []
nozzles = re.findall(r'<nozzle id="\d+" extruder_id="(\d+)"', si)
report(set(used_extruders) <= set(nozzles), 'slice_info has a <nozzle> entry for every extruder the plate uses', f'uses {used_extruders}, listed {nozzles}')
# project settings: a Flashforge host profile, like Orca's
import json
ps = json.loads(ours.read('Metadata/project_settings.config'))
report(ps.get('host_type') == 'flashforge', 'project_settings host_type is flashforge', str(ps.get('host_type')))
report(bool(ps.get('flashforge_serial_number')), 'project_settings carries the printer serial number', 'empty')
report(not any(k in ps for k in ('print_host', 'printhost_apikey', 'printhost_password')), 'project_settings has no host address / key entries')
report(len(ps.get('nozzle_volume_type', [])) == len(ps.get('nozzle_diameter', [])), 'project_settings nozzle_volume_type has one value per nozzle')
tail = full[-600000:].decode('latin1')
cfg = tail[tail.rfind('; CONFIG_BLOCK_START'):]
report(re.search(r'^; host_type = flashforge$', cfg, re.M) is not None, 'G-code config block host_type is flashforge')
report(re.search(r'^; flashforge_serial_number = \S+$', cfg, re.M) is not None, 'G-code config block carries the printer serial number')
report(re.search(r'^; print_host = ', cfg, re.M) is None, 'G-code config block has no print_host line')
ct = ours.read('[Content_Types].xml').decode()
report('Extension="json"' in ct and 'Extension="jpg"' in ct, '[Content_Types].xml lists json and jpg like Orca')
print(f'\n{bad} required difference(s)')
sys.exit(1 if bad else 0)
