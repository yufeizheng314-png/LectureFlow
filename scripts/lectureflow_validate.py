"""Small configuration/IPA gate; no third-party Python modules required."""
from pathlib import Path
import argparse, hashlib, json, plistlib, re, struct, subprocess, zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Examples/WhisperAX'
UPSTREAM = '9f99b5cb6a907730543823ad271b82532782a899'
PIN = 'c5d11a805e765f52ba34ec7284bd4fcd6ba68615'

def configuration():
    pbx = (BASE / 'WhisperAX.xcodeproj/project.pbxproj').read_text()
    sources = re.search(r'167B345A2B05431E0076F261 /\* Sources \*/ = \{(.*?)\n\t\t\};', pbx, re.S)[1]
    files = sorted((BASE / 'WhisperAX/LectureFlow').glob('*.swift'))
    assert len(files) >= 10
    for file in files:
        assert f'/* {file.name} in Sources */,' in sources, file.name
    assert 'ContentView.swift in Sources' not in sources
    target = re.search(r'167B345D2B05431E0076F261 /\* WhisperAX \*/ = \{(.*?)\n\t\t\};', pbx, re.S)[1]
    assert 'Embed Watch Content' not in target and 'SpeakerKit' not in target
    assert plistlib.loads((BASE / 'WhisperAX/Resources/WhisperAX.entitlements').read_bytes()) == {}
    info = plistlib.loads((BASE / 'WhisperAX/Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == 'LectureFlow' and info['UIBackgroundModes'] == ['audio']
    assert info['NSMicrophoneUsageDescription']
    assert 'exact: "1.7.0"' in (ROOT / 'Package.swift').read_text()
    for lock in [ROOT/'Package.resolved',BASE/'WhisperAX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved']:
        pins = json.loads(lock.read_text())['pins']
        assert len(pins) == 1 and pins[0]['state'] == {'revision': PIN, 'version': '1.7.0'}
    icon = BASE / 'WhisperAX/Resources/Assets.xcassets/LectureFlowIcon.appiconset'
    for item in json.loads((icon/'Contents.json').read_text())['images']:
        data = (icon/item['filename']).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[25] == 2, 'RGB, opaque PNG required'
        width, height = struct.unpack('>II', data[16:24])
        assert width == height == int(float(item['size'].split('x')[0])*int(item['scale'][0]))
    combined = (BASE/'WhisperAX/Resources/LectureFlow-Licenses.txt').read_text()
    for name in ['LICENSE','NOTICES']:
        assert (ROOT/name).read_text() in combined
    assert (BASE/'WhisperAX/LectureFlow/LectureFlowAudio-LICENSE.txt').read_text() in combined
    assert (BASE/'WhisperAX/Resources/OpenAI-Whisper-LICENSE.txt').read_text() in combined
    assert 'LectureFlowBaseEncoder.mlmodelc in Resources' in pbx
    subprocess.run(['git','merge-base','--is-ancestor',UPSTREAM,'HEAD'],cwd=ROOT,check=True)
    print(f'Configuration passed: {len(files)} app sources, iPad brand, opaque icons, permissions, license notices and exact dependency pin.')

def macho_unsigned(data):
    # The device build must be a thin arm64 Mach-O; reject any LC_CODE_SIGNATURE.
    assert data[:4] == b'\xcf\xfa\xed\xfe', 'Expected 64-bit little-endian Mach-O'
    assert struct.unpack_from('<I',data,4)[0] == 0x0100000C, 'Expected arm64'
    commands = struct.unpack_from('<I',data,16)[0]
    offset = 32
    for _ in range(commands):
        command, size = struct.unpack_from('<II',data,offset)
        assert command != 0x1D, 'Unexpected LC_CODE_SIGNATURE'
        assert size >= 8 and offset+size <= len(data)
        offset += size

def ipa(path, report):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        names = z.namelist()
        plist_names = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info.plist',n)]
        assert len(plist_names)==1
        prefix = plist_names[0][:-len('Info.plist')]
        info=plistlib.loads(z.read(plist_names[0]))
        for key,value in {'CFBundleIdentifier':'com.yufeizheng.lectureflow','CFBundleDisplayName':'LectureFlow','CFBundleShortVersionString':'0.2.0','CFBundleVersion':'3','UIDeviceFamily':[2],'UIBackgroundModes':['audio']}.items():
            assert info[key] == value, (key,info.get(key))
        assert float(info['MinimumOSVersion'])>=17.0
        assert info['NSMicrophoneUsageDescription']
        assert not any(any(part in n for part in ['_CodeSignature/','embedded.mobileprovision','/Watch/','/PlugIns/']) for n in names)
        executable = prefix+info['CFBundleExecutable']
        macho_unsigned(z.read(executable))
        assert (z.getinfo(executable).external_attr>>16)&0o111, 'Executable permission was not preserved'
        assert prefix+'LectureFlow-Licenses.txt' in names
        assert prefix+'PrivacyInfo.xcprivacy' in names
        encoder_prefix = prefix+'LectureFlowBaseEncoder.mlmodelc/'
        encoder_manifest_name = encoder_prefix+'lectureflow-encoder-manifest.json'
        encoder = json.loads(z.read(encoder_manifest_name))
        assert encoder['schema_version'] == 1 and encoder['model'] == 'openai/whisper-base'
        assert encoder['compute_precision'] == 'FLOAT32'
        assert encoder['base_sha256'] == 'ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e'
        assert encoder['input_shape'] == [1,80,1,3000] and encoder['output_shape'] == [1,512,1,1500]
        assert encoder['source_commit'] == subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        expected_encoder_files = set()
        for item in encoder['files']:
            relative = item['path']
            assert isinstance(relative,str) and relative and not relative.startswith('/') and '\\' not in relative
            assert all(part not in ('','.', '..') for part in relative.split('/'))
            assert relative != 'lectureflow-encoder-manifest.json' and relative not in expected_encoder_files
            expected_encoder_files.add(relative)
            assert re.fullmatch('[0-9a-f]{64}',item['sha256']) and type(item['bytes']) is int
            data = z.read(encoder_prefix+relative)
            assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], relative
        actual_encoder_files = {n[len(encoder_prefix):] for n in names if n.startswith(encoder_prefix) and not n.endswith('/') and n != encoder_manifest_name}
        assert actual_encoder_files == expected_encoder_files and 'coremldata.bin' in expected_encoder_files
        for name in names:
            if name.endswith('/') or name == executable: continue
            data=z.read(name)
            if data[:4] == b'\xcf\xfa\xed\xfe': macho_unsigned(data)
    result={'file':path.name,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'unsigned':True,'architecture':'arm64','bundle_id':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'minimum_os':info['MinimumOSVersion'],'device_family':info['UIDeviceFamily'],'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'upstream_commit':UPSTREAM,'argument_parser_commit':PIN,'bundled_encoder':encoder}
    report.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--ipa',type=Path)
    parser.add_argument('--report',type=Path,default=Path('IPA-VERIFICATION.json'))
    args=parser.parse_args()
    if args.ipa: ipa(args.ipa,args.report)
    else: configuration()
