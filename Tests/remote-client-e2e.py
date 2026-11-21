import array
import concurrent.futures
import hashlib
import hmac
import http.client
import json
import math
import pathlib
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse

root = pathlib.Path(sys.argv[1])
settings = json.loads((root / 'server-ready.json').read_text())
context = ssl._create_unverified_context()
checks = []


def check(name, result):
    checks.append({'name': name, 'passed': bool(result)})
    assert result, name


def request(path, token=None, method='GET', body=None, extra=None):
    connection = http.client.HTTPSConnection('127.0.0.1', settings['port'], context=context, timeout=15)
    headers = dict(extra or {})
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        body = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    connection.request(method, path, body, headers)
    response = connection.getresponse()
    data = response.read()
    result = response.status, dict(response.getheaders()), data
    connection.close()
    return result


def signature(message, password=None):
    return hmac.new((password or settings['password']).encode(), message.encode(), hashlib.sha256).hexdigest()


status, _, data = request('/v1/challenge')
challenge = json.loads(data)
fingerprint = settings['fingerprint']
check('server_proves_password_and_certificate', status == 200 and hmac.compare_digest(challenge['proof'], signature('server|' + challenge['nonce'] + '|' + fingerprint)))
status, _, _ = request('/v1/pair', method='POST', body={'nonce': challenge['nonce'], 'proof': signature('client|' + challenge['nonce'] + '|' + fingerprint, 'wrong-password')})
check('wrong_password_rejected', status == 401)
status, _, data = request('/v1/challenge')
malformed = json.loads(data)
check('unicode_proof_rejected_without_crash', request('/v1/pair', method='POST', body={'nonce': malformed['nonce'], 'proof': 'é' * 32})[0] == 401)
status, _, data = request('/v1/challenge')
challenge = json.loads(data)
pair = {'nonce': challenge['nonce'], 'proof': signature('client|' + challenge['nonce'] + '|' + fingerprint)}
status, _, data = request('/v1/pair', method='POST', body=pair)
token = json.loads(data)['token']
check('correct_password_pairs', status == 200)
check('challenge_replay_rejected', request('/v1/pair', method='POST', body=pair)[0] == 401)
check('missing_token_rejected', request('/v1/cameras')[0] == 401)
check('modified_token_rejected', request('/v1/cameras', token + 'x')[0] == 401)
expired_payload = 'a' * 43 + '.' + str(int(time.time()) - 1)
expired_token = expired_payload + '.' + signature('token|' + expired_payload)
check('expired_token_rejected', request('/v1/cameras', expired_token)[0] == 401)
status, _, data = request('/v1/cameras', token)
cameras = json.loads(data)
check('camera_list_includes_history', status == 200 and any(camera['id'] == 'offline:fixture' and not camera['online'] for camera in cameras))
check('two_live_cameras_listed', sum(camera['id'].startswith('wifi:') for camera in cameras) == 2)
status, _, data = request('/v1/recordings?sourceID=offline%3Afixture', token)
entries = json.loads(data)
check('offline_recordings_and_person_events', status == 200 and len(entries) == 1 and len(entries[0]['events']) == 1)
movie_id = (root / 'offline-id').read_text()
local = (root / 'library' / (movie_id + '.mov')).read_bytes()
path = '/v1/recordings/' + movie_id + '/movie'
status, headers, data = request(path, token, extra={'Range': 'bytes=0-511'})
check('movie_range_correct', status == 206 and data == local[:512] and headers.get('Content-Range') == 'bytes 0-511/' + str(len(local)))
status, _, data = request(path, token, extra={'Range': 'bytes=-128'})
check('movie_suffix_range_correct', status == 206 and data == local[-128:])
check('movie_out_of_bounds_rejected', request(path, token, extra={'Range': 'bytes=999999999-9999999999'})[0] == 416)
check('movie_missing_auth_rejected', request(path)[0] == 401)
check('path_traversal_rejected', request('/v1/recordings/%2E%2E/movie', token)[0] == 404)
check('partial_movie_hidden', request('/v1/recordings/.partial/movie', token)[0] == 404)
outside_id = (root / 'outside-id').read_text()
check('symlink_cannot_read_outside_library', request('/v1/recordings/' + outside_id + '/movie', token)[0] == 404)
status, _, data = request(path, token)
(root / 'download.mov').write_bytes(data)
check('full_movie_matches', status == 200 and data == local)
status, _, lease_data = request('/v1/recordings/' + movie_id + '/playback', token, method='POST')
check('playback_lease_created', status == 200)
lease_id = json.loads(lease_data)['id']
lease_header = {'X-WireCamera-Playback': lease_id, 'Range': 'bytes=128-255'}
status, _, leased_data = request(path, token, extra=lease_header)
check('leased_movie_range_correct', status == 206 and leased_data == local[128:256])
check('lease_cannot_access_other_recording', request('/v1/recordings/00000000-0000-0000-0000-000000000001/movie', token, extra=lease_header)[0] == 403)
other_payload = 'b' * 43 + '.' + str(int(time.time()) + 600)
other_token = other_payload + '.' + signature('token|' + other_payload)
check('lease_is_bound_to_paired_client', request('/v1/playback/' + lease_id, other_token, method='PUT')[0] == 403)
check('playback_lease_renewed', request('/v1/playback/' + lease_id, token, method='PUT')[0] == 204)
check('playback_lease_released', request('/v1/playback/' + lease_id, token, method='DELETE')[0] == 204)
check('released_lease_rejected', request(path, token, extra=lease_header)[0] == 410)
decoded = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(root / 'download.mov'), '-f', 'null', '-'], capture_output=True)
(root / 'download.decode.log').write_bytes(decoded.stderr)
check('downloaded_movie_fully_decodes', decoded.returncode == 0)


def stream(identifier, frequency):
    connection = http.client.HTTPSConnection('127.0.0.1', settings['port'], context=context, timeout=20)
    connection.request('GET', '/v1/live?sourceID=' + urllib.parse.quote(identifier), headers={'Authorization': 'Bearer ' + token})
    response = connection.getresponse()
    assert response.status == 200, response.status
    videos = []
    audio = bytearray()
    deadline = time.monotonic() + 9
    while time.monotonic() < deadline and (len(videos) < 4 or len(audio) < 16000):
        header = response.read(5)
        assert len(header) == 5, header
        kind, length = struct.unpack('>BI', header)
        payload = response.read(length)
        assert len(payload) == length
        if kind == 1:
            videos.append(payload)
        elif kind == 2:
            audio.extend(payload)
    connection.close()
    name = 'first' if frequency == 500 else 'second'
    samples = array.array('h', audio)
    if sys.byteorder != 'little':
        samples.byteswap()

    def power(tone):
        return sum(sample * math.cos(2 * math.pi * tone * index / 8000) for index, sample in enumerate(samples)) ** 2 + sum(sample * math.sin(2 * math.pi * tone * index / 8000) for index, sample in enumerate(samples)) ** 2

    check(name + '_live_video_and_audio', len(videos) >= 4 and len(audio) >= 16000 and power(frequency) > power(1000 if frequency == 500 else 500) * 2)
    (root / (name + '.pcm')).write_bytes(audio)
    (root / (name + '.jpg')).write_bytes(videos[-1])
    frame = 'person-frame.jpg' if frequency == 500 else 'module-jpeg-frame.jpg'
    reference = subprocess.run(['ffmpeg', '-v', 'error', '-i', 'Tests/Fixtures/' + frame, '-vf', 'scale=16:16', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    decoded = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(root / (name + '.jpg')), '-vf', 'scale=16:16', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    check(name + '_live_camera_pixels_match', len(decoded) == len(reference) and sum(abs(left - right) for left, right in zip(decoded, reference)) / len(reference) < 25)
    return True


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    futures = [executor.submit(stream, 'wifi:fixture-manual-device', 500), executor.submit(stream, 'wifi:fixture-preview-device', 1000)]
    for future in futures:
        future.result()
status, _, data = request('/v1/cameras', token)
check('phone_viewing_does_not_change_recording', any(camera['id'] == 'wifi:fixture-manual-device' and camera['recording'] for camera in json.loads(data)))
check('offline_live_rejected', request('/v1/live?sourceID=offline%3Afixture', token)[0] == 404)
for attempt in range(60):
    if (root / 'background-state.json').exists():
        break
    time.sleep(0.2)
background = json.loads((root / 'background-state.json').read_text())
check('closing_mac_window_keeps_recording_and_server', background['hidden'] and background['recording'] and background['savedCount'] >= 1 and request('/v1/cameras', token)[0] == 200)
(root / 'reopen-request').write_text('reopen')
for attempt in range(30):
    if (root / 'reopened-state.json').exists():
        break
    time.sleep(0.2)
reopened = json.loads((root / 'reopened-state.json').read_text())
check('tray_reopens_without_stopping_recording', reopened['visible'] and reopened['recording'])
report = {'passed': all(item['passed'] for item in checks), 'checks': checks}
(root / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
