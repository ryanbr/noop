#!/usr/bin/env python3
"""Refresh the homepage stat badges (docs/stats/*.json) from the live Forgejo API.

The README shows shields.io `endpoint` badges that read these public raw JSON files, so the
download counter etc. stay current. Run on a schedule (cron / Forgejo Action) or at release time.
Needs a forge token with write access at ~/.config/noop/forge_token.
"""
import urllib.request, json, base64, os
TOK=open(os.path.expanduser("~/.config/noop/forge_token")).read().strip()
API="https://noop.fans/api/v1/repos/NoopApp/noop"
def req(url, method="GET", data=None):
    h={"Authorization":"token "+TOK}
    if data is not None: h["Content-Type"]="application/json"
    r=urllib.request.urlopen(urllib.request.Request(url,data=data,headers=h,method=method),timeout=30)
    return r.status, r.read()
def write(path, label, message, color):
    content=json.dumps({"schemaVersion":1,"label":label,"message":str(message),"color":color})
    body={"message":"stats: refresh "+os.path.basename(path),"content":base64.b64encode(content.encode()).decode(),
          "branch":"main","author":{"name":"NoopApp","email":"thenoopapp@gmail.com"},
          "committer":{"name":"NoopApp","email":"thenoopapp@gmail.com"}}
    sha=None
    try: _,b=req(API+"/contents/"+path); sha=json.loads(b).get("sha")
    except urllib.error.HTTPError as e:
        if e.code!=404: raise
    if sha: body["sha"]=sha
    req(API+"/contents/"+path, "PUT" if sha else "POST", json.dumps(body).encode())
rels=[]; page=1
while True:
    _,b=req(f"{API}/releases?per_page=50&page={page}"); c=json.loads(b)
    if not c: break
    rels+=c
    if len(c)<50: break
    page+=1
total=sum(a.get("download_count",0) for r in rels for a in (r.get("assets") or []))
latest=max(rels,key=lambda r:(r.get("published_at") or ""))
this_rel=sum(a.get("download_count",0) for a in (latest.get("assets") or []))
_,b=req(API); repo=json.loads(b)
def cnt(state):
    n=0; p=1
    while p<=10:
        _,b=req(f"{API}/issues?state={state}&type=issues&limit=50&page={p}"); c=json.loads(b)
        n+=len(c)
        if len(c)<50: break
        p+=1
    return n
_,b=req(f"{API}/commits?limit=1"); last=json.loads(b)[0]["commit"]["author"]["date"][:10]
write("docs/stats/release.json","latest",latest["tag_name"],"E8B84B")
write("docs/stats/released.json","released",(latest.get("published_at") or "")[:10],"6B737B")
write("docs/stats/stars.json","stars",repo.get("stars_count",0),"E8B84B")
write("docs/stats/forks.json","forks",repo.get("forks_count",0),"6B737B")
write("docs/stats/open.json","open issues",cnt("open"),"E8B84B")
write("docs/stats/resolved.json","resolved",cnt("closed"),"C8902F")
write("docs/stats/lastcommit.json","last commit",last,"6B737B")
print(f"refreshed: {total:,} downloads, latest {latest['tag_name']}")
