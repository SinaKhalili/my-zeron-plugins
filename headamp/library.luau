-- The folder library's helper, run with python3 and nothing but its standard
-- library. `scan` lists the audio in the folders from Settings with each
-- file's tags and length; `read` hands one part of one of those files to the
-- deck as it plays. It only reads, and only inside the folders it is given.
return [====[
import base64, json, os, re, struct, sys, time

AUDIO = {
    '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac', '.flac': 'audio/flac',
    '.wav': 'audio/wav', '.ogg': 'audio/ogg', '.opus': 'audio/ogg', '.aiff': 'audio/aiff',
    '.aif': 'audio/aiff', '.wma': 'audio/x-ms-wma', '.webm': 'audio/webm',
}
ART_MAX = 512 * 1024
TEXT = {'TIT2': 'title', 'TPE1': 'artist', 'TALB': 'album', 'TT2': 'title', 'TP1': 'artist', 'TAL': 'album'}
MP3_KBPS = {
    True: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    False: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
}
MP3_RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def natural(text):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r'(\d+)', text)]


def synchsafe(b):
    return (b[0] & 0x7f) << 21 | (b[1] & 0x7f) << 14 | (b[2] & 0x7f) << 7 | (b[3] & 0x7f)


def image_type(data):
    if data[:3] == b'\xff\xd8\xff':
        return 'image/jpeg'
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return 'image/png'
    if data[:4] == b'GIF8':
        return 'image/gif'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return 'image/webp'
    return ''


def keep_art(info, data, front=True):
    kind = image_type(data)
    if kind and len(data) <= ART_MAX and (front or 'art' not in info):
        info['art'] = (kind, bytes(data))


def id3_text(data):
    if not data:
        return ''
    codec = {0: 'latin-1', 1: 'utf-16', 2: 'utf-16-be'}.get(data[0], 'utf-8')
    return data[1:].decode(codec, 'replace').split('\x00')[0].strip()


def id3_picture(data, old):
    wide = data[0] in (1, 2)
    if old:
        at = 4
    else:
        at = data.index(b'\x00', 1) + 1
    front = data[at] == 3
    at += 1
    if wide:
        while at + 1 < len(data) and (data[at] or data[at + 1]):
            at += 2
        at += 2
    else:
        at = data.index(b'\x00', at) + 1
    return data[at:], front


def id3(f, info, art):
    """Reads an ID3v2 tag a frame at a time; returns where the audio starts."""
    f.seek(0)
    head = f.read(10)
    if len(head) < 10 or head[:3] != b'ID3':
        return 0
    major, flags = head[3], head[5]
    end = 10 + synchsafe(head[6:10])
    after = end + (10 if flags & 0x10 else 0)
    if major not in (2, 3, 4) or flags & 0x80:
        return after
    at = 10
    if flags & 0x40 and major >= 3:
        extra = f.read(4)
        if len(extra) < 4:
            return after
        at += synchsafe(extra) if major == 4 else struct.unpack('>I', extra)[0] + 4
    width = 6 if major == 2 else 10
    while at + width <= end:
        f.seek(at)
        h = f.read(width)
        if len(h) < width or not h[:3].strip(b'\x00'):
            break
        if major == 2:
            name, size, packed = h[:3], int.from_bytes(h[3:6], 'big'), 0
        else:
            name = h[:4]
            size = synchsafe(h[4:8]) if major == 4 else struct.unpack('>I', h[4:8])[0]
            packed = h[9] & (0x0f if major == 4 else 0xc0)
        at += width
        if size <= 0 or at + size > end:
            break
        name = name.decode('latin-1')
        if packed:
            pass
        elif name in TEXT and size <= 4096:
            value = id3_text(f.read(size))
            if value:
                info.setdefault(TEXT[name], value)
        elif art and name in ('APIC', 'PIC') and size <= ART_MAX + 4096:
            try:
                data, front = id3_picture(f.read(size), major == 2)
                keep_art(info, data, front)
            except (ValueError, IndexError):
                pass
        at += size
    return after


def mp3(f, size, info, art):
    start = id3(f, info, art)
    tail = 0
    if size >= 128:
        f.seek(size - 128)
        old = f.read(128)
        if old[:3] == b'TAG':
            tail = 128
            for key, a, b in (('title', 3, 33), ('artist', 33, 63), ('album', 63, 93)):
                value = old[a:b].split(b'\x00')[0].decode('latin-1').strip()
                if value:
                    info.setdefault(key, value)
    f.seek(start)
    buf = f.read(65536)
    at = 0
    while True:
        at = buf.find(b'\xff', at)
        if at < 0 or at + 4 > len(buf):
            return
        h = buf[at:at + 4]
        version, layer = (h[1] >> 3) & 3, (h[1] >> 1) & 3
        kbps_at, rate_at = (h[2] >> 4) & 15, (h[2] >> 2) & 3
        if h[1] & 0xe0 == 0xe0 and version != 1 and layer == 1 and kbps_at not in (0, 15) and rate_at != 3:
            first = version == 3
            kbps, rate = MP3_KBPS[first][kbps_at], MP3_RATES[version][rate_at]
            length = (144 if first else 72) * kbps * 1000 // rate + ((h[2] >> 1) & 1)
            then = buf[at + length:at + length + 2]
            if len(then) < 2 or (then[0] == 0xff and then[1] & 0xe0 == 0xe0):
                break
        at += 1
    mono = (h[3] >> 6) == 3
    samples = 1152 if first else 576
    audio = max(0, size - start - at - tail)
    frames = 0
    side = at + 4 + ((17 if mono else 32) if first else (9 if mono else 17))
    if buf[side:side + 4] in (b'Xing', b'Info') and buf[side + 7] & 1:
        frames = struct.unpack('>I', buf[side + 8:side + 12])[0]
    elif buf[at + 36:at + 40] == b'VBRI':
        frames = struct.unpack('>I', buf[at + 50:at + 54])[0]
    if frames:
        info['duration'] = frames * samples / rate
        info['bitrate'] = audio * 8 / info['duration']
    else:
        info['duration'] = audio * 8 / (kbps * 1000)
        info['bitrate'] = kbps * 1000
    info['rate'], info['channels'] = rate, 1 if mono else 2


def comments(data, info):
    at = 4 + int.from_bytes(data[0:4], 'little')
    count = int.from_bytes(data[at:at + 4], 'little')
    at += 4
    for _ in range(min(count, 2000)):
        if at + 4 > len(data):
            break
        size = int.from_bytes(data[at:at + 4], 'little')
        key, _, value = data[at + 4:at + 4 + size].decode('utf-8', 'replace').partition('=')
        at += 4 + size
        key, value = key.upper(), value.strip()
        if key in ('TITLE', 'ARTIST', 'ALBUM') and value:
            info.setdefault(key.lower(), value)


def flac(f, size, info, art):
    f.seek(id3(f, {}, False))
    if f.read(4) != b'fLaC':
        return
    while True:
        h = f.read(4)
        if len(h) < 4:
            break
        kind, length, here = h[0] & 0x7f, int.from_bytes(h[1:4], 'big'), f.tell()
        if kind == 0 and length >= 18:
            packed = int.from_bytes(f.read(18)[10:18], 'big')
            info['rate'] = packed >> 44
            info['channels'] = ((packed >> 41) & 7) + 1
            total = packed & ((1 << 36) - 1)
            if info['rate'] and total:
                info['duration'] = total / info['rate']
        elif kind == 4 and length <= 1 << 20:
            comments(f.read(length), info)
        elif kind == 6 and art and length <= ART_MAX + 4096:
            d = f.read(length)
            at = 8 + int.from_bytes(d[4:8], 'big')
            at += 4 + int.from_bytes(d[at:at + 4], 'big') + 16
            n = int.from_bytes(d[at:at + 4], 'big')
            keep_art(info, d[at + 4:at + 4 + n], int.from_bytes(d[0:4], 'big') == 3)
        f.seek(here + length)
        if h[0] & 0x80:
            break
    if info.get('duration'):
        info['bitrate'] = max(0, size - f.tell()) * 8 / info['duration']


def atoms(f, start, end):
    at = start
    while at + 8 <= end:
        f.seek(at)
        h = f.read(8)
        if len(h) < 8:
            return
        size, head = struct.unpack('>I', h[:4])[0], 8
        if size == 1:
            size, head = struct.unpack('>Q', f.read(8))[0], 16
        elif size == 0:
            size = end - at
        if size < head or at + size > end:
            return
        yield h[4:8], at + head, at + size
        at += size


def mp4(f, size, info, art):
    names = {b'\xa9nam': 'title', b'\xa9ART': 'artist', b'\xa9alb': 'album'}
    for kind, a, b in atoms(f, 0, size):
        if kind != b'moov':
            continue
        for kind, a, b in atoms(f, a, b):
            if kind == b'mvhd':
                f.seek(a)
                d = f.read(32)
                scale, length = struct.unpack('>IQ', d[20:32]) if d[0] == 1 else struct.unpack('>II', d[12:20])
                if scale:
                    info['duration'] = length / scale
            elif kind == b'trak' and 'rate' not in info:
                for kind2, a2, b2 in atoms(f, a, b):
                    if kind2 != b'mdia':
                        continue
                    scale, sound = 0, False
                    for kind3, a3, b3 in atoms(f, a2, b2):
                        f.seek(a3)
                        d = f.read(24)
                        if kind3 == b'mdhd':
                            scale = struct.unpack('>I', d[20:24] if d[0] == 1 else d[12:16])[0]
                        elif kind3 == b'hdlr':
                            sound = d[8:12] == b'soun'
                    if sound and scale:
                        info['rate'] = scale
            elif kind == b'udta':
                for kind2, a2, b2 in atoms(f, a, b):
                    if kind2 != b'meta':
                        continue
                    for kind3, a3, b3 in atoms(f, a2 + 4, b2):
                        if kind3 != b'ilst':
                            continue
                        for item, a4, b4 in atoms(f, a3, b3):
                            wanted = item in names or (art and item == b'covr')
                            if not wanted or b4 - a4 > ART_MAX + 4096:
                                continue
                            for kind5, a5, b5 in atoms(f, a4, b4):
                                if kind5 != b'data' or b5 - a5 < 8:
                                    continue
                                f.seek(a5 + 8)
                                d = f.read(b5 - a5 - 8)
                                if item == b'covr':
                                    keep_art(info, d)
                                elif d.strip():
                                    info.setdefault(names[item], d.decode('utf-8', 'replace').strip())
                                break
    if info.get('duration'):
        info['bitrate'] = size * 8 / info['duration']
        info.setdefault('channels', 2)


def wav(f, size, info, art):
    f.seek(0)
    h = f.read(12)
    if h[:4] != b'RIFF' or h[8:12] != b'WAVE':
        return
    at, pace = 12, 0
    while at + 8 <= size:
        f.seek(at)
        h = f.read(8)
        if len(h) < 8:
            return
        length = struct.unpack('<I', h[4:8])[0]
        if h[:4] == b'fmt ':
            d = f.read(16)
            info['channels'], info['rate'], pace = struct.unpack('<HII', d[2:12])
        elif h[:4] == b'data':
            if pace:
                info['duration'] = min(length, size - at - 8) / pace
                info['bitrate'] = pace * 8
            return
        at += 8 + length + (length & 1)


READERS = {'.mp3': mp3, '.flac': flac, '.m4a': mp4, '.wav': wav}


def describe(path, ext, size, art=False):
    info = {}
    reader = READERS.get(ext)
    if reader:
        try:
            with open(path, 'rb') as f:
                reader(f, size, info, art)
        except Exception:
            pass
    return info


def inside(path, roots):
    for root in roots:
        try:
            if os.path.commonpath([path, root]) == root:
                return True
        except ValueError:
            pass
    return False


def resolve(folder):
    return os.path.realpath(os.path.expanduser(folder.strip()))


def scan(limit, folders):
    began = time.time()
    seen, copies, rows, report, cut = set(), set(), [], [], False
    for folder in folders:
        root = resolve(folder)
        entry = {'folder': folder, 'found': os.path.isdir(root), 'tracks': 0}
        report.append(entry)
        if not entry['found']:
            continue
        found = []
        for base, dirs, files in os.walk(root):
            dirs[:] = [name for name in dirs if not name.startswith('.')]
            for name in files:
                if not name.startswith('.') and os.path.splitext(name)[1].lower() in AUDIO:
                    found.append(os.path.join(base, name))
        found.sort(key=lambda path: [natural(part) for part in os.path.relpath(path, root).split(os.sep)])
        for listed in found:
            path = os.path.realpath(listed)
            if path in seen or not inside(path, [root]):
                continue
            if len(rows) >= limit:
                cut = True
                break
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            seen.add(path)
            name, ext = os.path.splitext(os.path.basename(path))
            # A slow disk: past the budget, list the rest by name alone.
            info = describe(path, ext.lower(), size) if time.time() - began < 20 else {}
            # The same recording kept twice (a copy in the Music app's library).
            copy = (size, info.get('duration'), info.get('title'), info.get('artist'), info.get('album'))
            if info.get('duration') and info.get('title'):
                if copy in copies:
                    continue
                copies.add(copy)
            rows.append([
                path, info.get('title') or name, info.get('artist') or '', info.get('album') or '',
                round(info.get('duration') or 0, 2), int(info.get('bitrate') or 0),
                int(info.get('rate') or 0), int(info.get('channels') or 0), size,
            ])
            entry['tracks'] += 1
    # A line of what was found, then the tracks: the deck's `library` argument.
    sys.stdout.write(json.dumps({'tracks': len(rows), 'folders': report, 'cut': cut}) + '\n')
    sys.stdout.write(json.dumps(rows, separators=(',', ':')))


def read(seq, offset, length, art, path, folders):
    real = os.path.realpath(path)
    ext = os.path.splitext(real)[1].lower()
    if ext not in AUDIO or not inside(real, [resolve(folder) for folder in folders]) or not os.path.isfile(real):
        sys.exit('not a track in the music folders')
    size = os.path.getsize(real)
    head = {'size': size, 'offset': offset, 'mime': AUDIO[ext]}
    if art:
        found = describe(real, ext, size, True).get('art')
        if found:
            head['art'] = [found[0], base64.b64encode(found[1]).decode('ascii')]
    with open(real, 'rb') as f:
        f.seek(offset)
        data = f.read(max(0, min(length, 1024 * 1024)))
    head['length'] = len(data)
    # The deck's `feed` call, whole, so the plugin passes it on as it is:
    # every copy it made of a part would count against its small memory.
    sys.stdout.write('window.headamp&&window.headamp.feed?window.headamp.feed(%d,' % seq + json.dumps(head)
                     + ',"' + base64.b64encode(data).decode('ascii') + '"):null')


if __name__ == '__main__':
    mode, rest = sys.argv[1], sys.argv[2:]
    if mode == 'scan':
        scan(int(rest[0]), rest[1:])
    elif mode == 'read':
        read(int(rest[0]), int(rest[1]), int(rest[2]), rest[3] == '1', rest[4], rest[5:])
]====]
