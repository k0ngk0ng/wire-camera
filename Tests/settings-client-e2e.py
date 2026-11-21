import hashlib
import hmac
import http.client
import json
import pathlib
import ssl
import sys
import time

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]


def wait_file(name):
    for attempt in range(300):
        path = root / name
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(0.2)
    raise AssertionError('Timed out waiting for ' + name)


ready = wait_file(mode + '-ui-ready.json')
settings = json.loads((root / 'remote/settings.json').read_text())
manifest = json.loads((root / 'manifest.json').read_text())
context = ssl._create_unverified_context()


def request(path, token=None, method='GET', body=None):
    connection = http.client.HTTPSConnection('127.0.0.1', ready['port'], context=context, timeout=15)
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = 'application/json'
        body = json.dumps(body).encode()
    connection.request(method, path, body, headers)
    certificate = connection.sock.getpeercert(binary_form=True) if connection.sock else None
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data, certificate


if mode == 'first':
    status, data, certificate = request('/v1/challenge')
    challenge = json.loads(data)
    fingerprint = hashlib.sha256(certificate).hexdigest()

    def proof(message):
        return hmac.new(settings['password'].encode(), message.encode(), hashlib.sha256).hexdigest()

    assert status == 200 and challenge['proof'] == proof('server|' + challenge['nonce'] + '|' + fingerprint)
    status, data, _ = request('/v1/pair', method='POST', body={'nonce': challenge['nonce'], 'proof': proof('client|' + challenge['nonce'] + '|' + fingerprint)})
    assert status == 200
    token = json.loads(data)['token']
    lease_status, lease_data, _ = request('/v1/recordings/' + manifest['movies']['leased'] + '/playback', token, method='POST')
    assert lease_status == 200
    lease_id = json.loads(lease_data)['id']
    (root / 'client-session.json').write_text(json.dumps({'token': token, 'fingerprint': fingerprint}))
    connection = http.client.HTTPSConnection('127.0.0.1', ready['port'], context=context, timeout=15)
    connection.request('GET', '/v1/recordings/' + manifest['movies']['downloading'] + '/movie', headers={'Authorization': 'Bearer ' + token})
    response = connection.getresponse()
    assert response.status == 200
    assert response.read(64)
    (root / 'client-reading').write_text('ready')
    wait_file('cleanup-ready.json')
    assert request('/v1/cameras', token)[0] == 200
    assert response.read(64)
    response.close()
    connection.close()
    assert request('/v1/playback/' + lease_id, token, method='DELETE')[0] == 204
    (root / 'client-released').write_text('released')
else:
    session = json.loads((root / 'client-session.json').read_text())
    status, _, certificate = request('/v1/cameras', session['token'])
    assert status == 200 and hashlib.sha256(certificate).hexdigest() == session['fingerprint']
    (root / 'restore-network-checked').write_text('checked')
report = wait_file(mode + '-result.json')
assert report['passed'], report
