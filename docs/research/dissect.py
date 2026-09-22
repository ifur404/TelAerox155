#!/usr/bin/env python3
"""dissect.py -- Reassembly + dissect protokol BLE SCCU (Yamaha) dari Apple PacketLogger (.pklg).

Perbaikan atas analisis lama (capture-findings.md v1):
  * Arah diambil dari TIPE RECORD HCI: 0x02 = ACL Data Sent (phone->CCU),
    0x03 = ACL Data Received (CCU->phone). BUKAN dari PB flag.
  * Reassembly L2CAP: PB=00/10 mulai PDU baru (panjang di 2 byte pertama
    L2CAP header, LE); PB=01 disambung sampai panjang kepenuhan, baru parse
    ATT dari PDU utuh.

Pemakaian:
  python dissect.py Aerox-155.pklg Sample_SCCU1_MappingFile.json out.json
"""

import struct, json, sys, collections, statistics

PKLG = sys.argv[1] if len(sys.argv) > 1 else 'Aerox-155.pklg'
MAPF = sys.argv[2] if len(sys.argv) > 2 else 'Sample_SCCU1_MappingFile.json'
OUT  = sys.argv[3] if len(sys.argv) > 3 else 'dissect-out.json'

HCI_DIR = {0x02: 'phone->CCU', 0x03: 'CCU->phone'}
HCI_NM  = {0x02: 'ACL_SENT', 0x03: 'ACL_RECV'}

# ---------------------------------------------------------------------------
# 1. Load pklg
# ---------------------------------------------------------------------------
raw = open(PKLG, 'rb').read()
recs = []
pos = 32
while pos < len(raw):
    L = struct.unpack('<I', raw[pos:pos + 4])[0]
    p = raw[pos + 4:pos + 4 + L]
    pos += 4 + L
    sec  = struct.unpack('<I', p[0:4])[0]
    usec = struct.unpack('<I', p[4:8])[0]
    recs.append({'ts': sec * 1000000 + usec, 'hci': p[8], 'data': p[9:]})

# ---------------------------------------------------------------------------
# 2. Fingerprint tipe HCI + ekstrak ACL + reassemble L2CAP
# ---------------------------------------------------------------------------
hci_counter = collections.Counter(r['hci'] for r in recs)

acl_pkts = []
for r in recs:
    h = r['hci']
    if h not in HCI_DIR:
        continue
    d = r['data']
    if len(d) < 4:
        continue
    hdr = struct.unpack('<H', d[0:2])[0]
    dlen = struct.unpack('<H', d[2:4])[0]
    acl_pkts.append({
        'ts': r['ts'], 'hci': h, 'dir': HCI_DIR[h],
        'handle': hdr & 0x0FFF, 'pb': (hdr >> 12) & 0x3,
        'payload': d[4:4 + dlen],
    })

pb_stat = collections.Counter((p['dir'], p['pb']) for p in acl_pkts)

pdus = []
pending = {}
orphan = 0
for pkt in acl_pkts:
    key = (pkt['dir'], pkt['handle'])
    if pkt['pb'] in (0, 2):
        buf = bytearray(pkt['payload'])
        if len(buf) < 4:
            continue
        l2len = struct.unpack('<H', buf[0:2])[0]
        cid = struct.unpack('<H', buf[2:4])[0]
        need = 4 + l2len
        st = {'buf': buf, 'need': need, 'cid': cid, 'ts': pkt['ts'],
              'dir': pkt['dir'], 'handle': pkt['handle']}
        pending[key] = st
        if len(buf) >= need:
            pdus.append({'ts': pkt['ts'], 'dir': pkt['dir'], 'handle': pkt['handle'],
                         'cid': cid, 'pdu': bytes(buf[:need])})
            del pending[key]
    elif pkt['pb'] == 1:
        st = pending.get(key)
        if st is None:
            orphan += 1
            continue
        st['buf'] += pkt['payload']
        if len(st['buf']) >= st['need']:
            pdus.append({'ts': st['ts'], 'dir': st['dir'], 'handle': st['handle'],
                         'cid': st['cid'], 'pdu': bytes(st['buf'][:st['need']])})
            del pending[key]

cid_counter = collections.Counter(x['cid'] for x in pdus)

# ---------------------------------------------------------------------------
# 3. Parse ATT dari PDU utuh (cid 0x0004)
# ---------------------------------------------------------------------------
att = []
for x in pdus:
    if x['cid'] != 0x0004:
        continue
    sdu = x['pdu'][4:]
    if not sdu:
        continue
    op = sdu[0]
    rec = {'ts': x['ts'], 'dir': x['dir'], 'op': op, 'sdu_bytes': len(sdu)}
    if op in (0x1B, 0x12, 0x52, 0x0A, 0x08, 0x04, 0x02, 0x06, 0x18, 0x16) and len(sdu) >= 3:
        rec['ah'] = struct.unpack('<H', sdu[1:3])[0]
        rec['value'] = sdu[3:]
    else:
        rec['ah'] = None
        rec['value'] = sdu[1:]
    att.append(rec)
att.sort(key=lambda z: z['ts'])

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def cksum(fr):
    return (256 - (sum(fr[:-1]) & 0xFF)) & 0xFF

def cksum_ok(fr):
    return len(fr) >= 2 and cksum(fr) == fr[-1]

def walk_tlv(fr):
    n = fr[1]
    p = 2
    out = []
    for i in range(n):
        if p + 3 > len(fr):
            return None, 'rec %d header beyond frame' % i
        lid = fr[p:p + 2]
        ln = fr[p + 2]
        end = p + 3 + ln
        if end > len(fr):
            return None, 'rec %d lid=%s len=%d end=%d > len=%d' % (i, lid.hex(' '), ln, end, len(fr))
        out.append({'i': i, 'lid': lid.hex(' '), 'len': ln, 'start': p,
                    'data_off': p + 3, 'end': end})
        p = end
    return out, None

# ---------------------------------------------------------------------------
# 4. Ringkasan + checksum per tipe (INBOUND notification ah 0x0F)
# ---------------------------------------------------------------------------
notifs = [r for r in att if r['dir'] == 'CCU->phone' and r['op'] == 0x1B and r['ah'] == 0x0F]
by_type = collections.defaultdict(list)
for n in notifs:
    if n['value']:
        by_type[n['value'][0]].append(n)

def stats(lst):
    if not lst:
        return {}
    lens = [len(n['value']) for n in lst]
    ok = sum(1 for n in lst if cksum_ok(n['value']))
    ts = [n['ts'] for n in lst]
    iv = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    return {'n': len(lst), 'len_min': min(lens), 'len_max': max(lens),
            'len_mode': collections.Counter(lens).most_common(1)[0][0],
            'len_avg': round(sum(lens) / len(lens), 1),
            'cksum_ok': ok, 'cksum_pct': round(100 * ok / len(lst), 1),
            'iv_med_us': statistics.median(iv) if iv else None,
            'ts_first': ts[0], 'ts_last': ts[-1]}

rx_by_type = {'0x%02X' % k: stats(by_type[k]) for k in sorted(by_type)}

op_counter = collections.Counter((r['dir'], r['op']) for r in att)

# ---------------------------------------------------------------------------
# 5. Auth + StartProcessing
# ---------------------------------------------------------------------------
auth = next((r for r in att if r['dir'] == 'phone->CCU' and r['op'] == 0x52
             and r['value'] and r['value'][0] == 0xAA), None)
sp = next((r for r in att if r['dir'] == 'CCU->phone' and r['op'] == 0x1B
           and r['value'] and r['value'][0] == 0x5A), None)

def auth_dec(fr):
    return {
        'frame_hex': fr.hex(), 'len': len(fr),
        'b0': '0x%02X' % fr[0], 'b1': '0x%02X' % fr[1],
        'b2_b3_le': '0x%04X' % struct.unpack('<H', fr[2:4])[0],
        'b2_b3_be': '0x%04X' % struct.unpack('>H', fr[2:4])[0],
        'b4': '0x%02X' % fr[4],
        'ccuid': fr[5:19].decode('ascii', 'replace'),
        'passKey': fr[19:25].decode('ascii', 'replace'),
        'phoneUUID': fr[25:57].decode('ascii', 'replace'),
        'b57_bond': fr[57], 'counter': fr[58],
        'cksum_calc': cksum(fr), 'cksum_actual': fr[-1], 'cksum_ok': cksum_ok(fr),
    }

auth_res = auth_dec(auth['value']) if auth else {}
sp_res = ({'frame_hex': sp['value'].hex(), 'len': len(sp['value']),
           'startProcessingFlag': sp['value'][5] if len(sp['value']) > 5 else None,
           'cksum_ok': cksum_ok(sp['value'])} if sp else {})

# ---------------------------------------------------------------------------
# 6. TLV 0x55 + odometer
# ---------------------------------------------------------------------------
f55 = [n['value'] for n in by_type.get(0x55, [])]
tlv_ok = collections.Counter()
tlv_err = collections.Counter()
shape_examples = {}
for fr in f55:
    recs_, err = walk_tlv(fr)
    if err:
        tlv_err[err] += 1
    else:
        shape = tuple((r['lid'], r['len']) for r in recs_)
        tlv_ok[shape] += 1
        if shape not in shape_examples:
            shape_examples[shape] = fr.hex()

tlv_summary = {'ok_shapes': {str(k): v for k, v in tlv_ok.items()},
               'errors': dict(tlv_err),
               'examples': {str(k): v for k, v in shape_examples.items()}}

odo = []
for fr in f55:
    if len(fr) < 45:
        continue
    b = fr[41:45]
    be = struct.unpack('>I', b)[0]
    le = struct.unpack('<I', b)[0]
    odo.append({'raw': b.hex(), 'be': be, 'be_km': be / 10.0, 'le': le, 'le_km': le / 10.0})

# ---------------------------------------------------------------------------
# 7. Factor fitting (LocalRecord) terhadap frame 0x55
# ---------------------------------------------------------------------------
sm = json.load(open(MAPF, encoding='utf-8'))
loc = sm.get('LocalRecord', [])
uniq = {}
for it in loc:
    k = (it['ID'], it['ByteNo'], it['Length'], it['Format'],
         it['FactorTop'], it['FactorBottom'], it['Offset'], it.get('Unit', ''))
    if k not in uniq:
        uniq[k] = it['ItemName']

long55 = next((f for f in f55 if len(f) >= 45), f55[0] if f55 else b'')

def raw_of(fr, bno, nbits, fmt):
    nb = max(1, nbits // 8)
    if not fr or bno + nb > len(fr):
        return None
    b = fr[bno:bno + nb]
    if nb == 1:
        return {'be': b[0], 'le': b[0]}
    if nb == 2:
        return {'be': struct.unpack('>H', b)[0], 'le': struct.unpack('<H', b)[0]}
    if nb == 4:
        return {'be': struct.unpack('>I', b)[0], 'le': struct.unpack('<I', b)[0]}
    return {'hex': b.hex()}

fields = []
for k, name in sorted(uniq.items()):
    idn, bno, nbits, fmt, ft, fb, off, unit = k
    fields.append({'id': idn, 'name': name, 'ByteNo': bno, 'bits': nbits,
                   'fmt': fmt, 'factorTop': ft, 'factorBottom': fb, 'offset': off,
                   'unit': unit, 'raw': raw_of(long55, bno, nbits, fmt),
                   'frame_len': len(long55)})

# ---------------------------------------------------------------------------
# 8. Frame 0xA6
# ---------------------------------------------------------------------------
a6_frames = [r['value'] for r in att if r['dir'] == 'phone->CCU' and r['op'] == 0x52
             and r['value'] and r['value'][0] == 0xA6]
a6_cmds = collections.Counter(fr[2:4].hex(' ') for fr in a6_frames if len(fr) >= 4)
a6_parsed = []
a6_ts = []
for r in att:
    if r['dir'] == 'phone->CCU' and r['op'] == 0x52 and r['value'] and r['value'][0] == 0xA6:
        a6_ts.append({'ts': r['ts'], 'hex': r['value'].hex(' ')})

DT_CMD = bytes.fromhex('058a')
a6_dt = []
for fr in a6_frames:
    if len(fr) >= 13 and fr[2:4] == DT_CMD:
        plen = fr[4]
        payload = fr[5:5 + plen]
        tail = fr[5 + plen:]
        a6_dt.append({
            'payload': payload.hex(' '), 'plen': plen,
            'last_payload_byte': payload[-1] if len(payload) >= 1 else None,
            'counter': tail[0] if tail else None,
            'cksum': tail[1] if len(tail) > 1 else None,
            'cksum_ok': cksum_ok(fr),
            'len': len(fr),
        })

# telemetry start vs first 0xA6
first_a6 = a6_ts[0]['ts'] if a6_ts else None
first_55 = by_type[0x55][0]['ts'] if by_type.get(0x55) else None
first_59 = by_type[0x59][0]['ts'] if by_type.get(0x59) else None

# ---------------------------------------------------------------------------
# 9. Frame 0x59 & 0x5B penuh
# ---------------------------------------------------------------------------
f59 = [n['value'] for n in by_type.get(0x59, [])]
f5b = [n['value'] for n in by_type.get(0x5B, [])]
f57 = [n['value'] for n in by_type.get(0x57, [])]
f56 = [n['value'] for n in by_type.get(0x56, [])]

def dump_samples(frames, limit):
    out = []
    for fr in frames[:limit]:
        recs_, err = walk_tlv(fr)
        out.append({'hex': fr.hex(' ')[:160], 'len': len(fr),
                    'tlv': None if err else [{'lid': r['lid'], 'len': r['len'],
                                              'data': fr[r['data_off']:r['end']].hex(' ')} for r in recs_],
                    'tlv_err': err})
    return out

f59_dec = dump_samples(f59, 8)
f5b_dec = dump_samples(f5b, 8)
f56_dec = dump_samples(f56, 2)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
res = {
    'pklg_total_records': len(recs),
    'hci_type_counter': {('%02X' % k): v for k, v in sorted(hci_counter.items())},
    'acl_packets': len(acl_pkts),
    'pb_stat': {str(k): v for k, v in sorted(pb_stat.items())},
    'orphan_pb1': orphan,
    'l2cap_pdus': len(pdus),
    'cid_counter': {'0x%04X' % k: v for k, v in sorted(cid_counter.items())},
    'att_events': len(att),
    'op_counter': {str(k): v for k, v in sorted(op_counter.items())},
    'nus_notifications': len(notifs),
    'mtu': {'client_request': '0x025&0x0125', 'server_response': '0x00F7=247',
            'negotiated': 247},
    'auth': auth_res,
    'startprocessing': sp_res,
    'rx_by_type': rx_by_type,
    'tlv_0x55': tlv_summary,
    'odometer_0x55': odo[:12],
    'fields_to_fix': fields,
    'a6': {'n': len(a6_frames), 'cmds': {k: v for k, v in sorted(a6_cmds.items())},
           'dt': a6_dt[:8]},
    'first_a6_ts': first_a6, 'first_0x55_ts': first_55, 'first_0x59_ts': first_59,
    'f59': f59_dec,
    'f5b': f5b_dec,
    'f56': f56_dec,
    'f57': f57[:2],
}

with open(OUT, 'w', encoding='utf-8') as fo:
    json.dump(res, fo, indent=1, default=str)
print(json.dumps(res, indent=1, default=str))