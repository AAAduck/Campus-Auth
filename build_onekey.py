# -*- coding: utf-8 -*-
"""Assemble one-key installer: standalone ps1 (test) + polyglot bat (deliverable)."""
import io, os

BASE = os.path.dirname(os.path.abspath(__file__))  # script dir: template + fixed task json + outputs live here
PROJ = r"D:\桌面\campus-auth-v5.0.0-alpha.10-x86_64-pc-windows-msvc"
MARK = "#CAMPUSAUTH_PS#"

tpl = io.open(os.path.join(BASE, "onekey-template.ps1.tpl"), encoding="utf-8").read()

preset = os.path.join(BASE, "preset-settings.json")   # captured from user's real config; keeps rebuild independent of the install dir
settings = io.open(preset if os.path.exists(preset) else os.path.join(PROJ, "config", "settings.json"), encoding="utf-8").read().strip()
task = io.open(os.path.join(BASE, "campus-auth-default-fixed.json"), encoding="utf-8").read().strip()
order = '{\n  "order": [\n    "default"\n  ],\n  "active": "default"\n}'

for name, blob in (("settings", settings), ("task", task), ("order", order)):
    assert not any(ln.startswith("'@") for ln in blob.splitlines()), f"'@ at line start in {name}"

body = (tpl.replace("@@SETTINGS_JSON@@", settings)
           .replace("@@TASK_JSON@@", task)
           .replace("@@ORDER_JSON@@", order))
assert MARK not in body and "@@" not in body

# 1) standalone ps1 (direct-run/testing): UTF-8 BOM + CRLF
ps1 = os.path.join(BASE, "campus-auth-onekey-setup.ps1")
io.open(ps1, "w", encoding="utf-8-sig", newline="\r\n").write(body)

# 2) single-file polyglot bat: ASCII cmd header reads the rest as UTF-8 PowerShell
#    - split pattern built by concat so the full marker appears ONLY once (own line)
#    - newline='' + manual CRLF conversion to avoid double-\r translation
head = (
    "@echo off\r\n"
    "rem campus-auth one-click installer - double click to run (cmd header, PS body below)\r\n"
    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"iex ([IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8) -split ('#' + 'CAMPUSAUTH_PS' + '#'),2)[1]\"\r\n"
    "pause\r\n"
    "exit /b\r\n"
    + MARK + "\r\n"
)
body_crlf = body.replace("\r\n", "\n").replace("\n", "\r\n")
bat = os.path.join(BASE, "campus-auth-一键安装.bat")
io.open(bat, "w", encoding="utf-8", newline="").write(head + body_crlf)

print("ps1:", os.path.getsize(ps1), "bytes")
print("bat:", os.path.getsize(bat), "bytes (polyglot, single file)")
