#!/usr/bin/env python3
"""Verify Lucent's direct Emby APIs using a password in the macOS login keychain.

Store a password with:
  security add-generic-password -a root -s com.lucent.emby.v398000xyz -w -U

No credentials or access tokens are written to this repository.
"""
import json
import subprocess
import urllib.parse
import urllib.request

BASE = "https://v.398000.xyz/emby"
ACCOUNT = "root"
KEYCHAIN_SERVICE = "com.lucent.emby.v398000xyz"
HEADERS = {
    "X-Emby-Authorization": 'Emby Client="Lucent", Device="Verification", DeviceId="lucent-direct-verification", Version="0.1.0"',
}


def request(path, token=None, payload=None):
    headers = dict(HEADERS)
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        headers["Content-Type"] = "application/json"
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(BASE + path, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def main():
    password = subprocess.check_output(
        ["security", "find-generic-password", "-a", ACCOUNT,
         "-s", KEYCHAIN_SERVICE, "-w"], text=True).strip()
    login = request("/Users/AuthenticateByName", payload={"Username": ACCOUNT, "Pw": password})
    token = login["AccessToken"]
    user_id = login["User"]["Id"]
    views = request(f"/Users/{user_id}/Views", token)["Items"]
    assert views, "No Emby libraries returned"
    print(f"Login OK; {len(views)} libraries")

    series = None
    for view in views:
        params = urllib.parse.urlencode({"ParentId": view["Id"], "Recursive": "false", "Limit": 100})
        items = request(f"/Users/{user_id}/Items?{params}", token)["Items"]
        series = next((item for item in items if item.get("Type") == "Series"), None)
        if series:
            break
    assert series, "No series found for verification"
    series_id = series["Id"]
    detail = request(f"/Users/{user_id}/Items/{series_id}?Fields=People,Genres,Overview", token)
    params = urllib.parse.urlencode({"UserId": user_id, "Limit": 200,
                                     "Fields": "Overview,MediaSources", "EnableUserData": "true"})
    episodes_page = request(f"/Shows/{series_id}/Episodes?{params}", token)
    episodes = episodes_page["Items"]
    assert episodes and episodes_page["TotalRecordCount"] > 0, "No episodes returned"
    assert detail.get("People"), "Series people missing"
    assert detail.get("Genres"), "Series genres missing"
    episode = episodes[0]
    item = request(f"/Users/{user_id}/Items/{episode['Id']}", token)
    assert item.get("SeriesId") == series_id, "Episode does not link to series"
    assert episode.get("MediaSources"), "Episode media sources missing"
    print(f"Series OK: {series['Name']}; {episodes_page['TotalRecordCount']} episodes; "
          f"{len(detail['People'])} people; {len(detail['Genres'])} genres")

    artwork = urllib.request.Request(
        BASE + f"/Items/{series_id}/Images/Backdrop/0?maxWidth=600",
        headers={**HEADERS, "X-Emby-Token": token})
    with urllib.request.urlopen(artwork, timeout=30) as response:
        assert response.status == 200 and response.headers.get_content_type().startswith("image/")
        print(f"Backdrop OK: {response.headers.get_content_type()}")

    stream = urllib.request.Request(
        BASE + f"/Videos/{episode['Id']}/stream?static=true",
        headers={**HEADERS, "X-Emby-Token": token, "Range": "bytes=0-1023"})
    with urllib.request.urlopen(stream, timeout=30) as response:
        assert response.status in (200, 206), f"Stream returned {response.status}"
        assert response.read(1024), "Stream returned no bytes"
        print(f"Direct stream OK: HTTP {response.status}; "
              f"{response.headers.get_content_type()}")


if __name__ == "__main__":
    main()
