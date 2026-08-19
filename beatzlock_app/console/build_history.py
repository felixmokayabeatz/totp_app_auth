import json
import os
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

from django.conf import settings
from django.contrib.admin.views.decorators import staff_member_required
from django.shortcuts import render
from django.utils.dateparse import parse_datetime


PLATFORMS = ("windows", "linux", "android")
PLATFORM_LABELS = {
    "windows": "Windows",
    "linux": "Linux",
    "android": "Android",
}
ARTIFACT_LABELS = {
    "exe_bundle": "App",
    "installer": "Installer",
    "apk": "APK",
    "aab": "AAB",
    "deb": "DEB",
    "linux_build": "Build",
    "unknown": "Unknown",
}


def _default_build_logs_dir() -> Path:
    # The Flutter client is a sibling directory inside this repo now, so the
    # logs it writes sit right next to this project rather than two levels up
    # in a separate totp_app checkout.
    return Path(settings.BASE_DIR).resolve() / "otp_auth_app" / "build_logs"


def _build_logs_dir() -> Path:
    configured = getattr(settings, "BEATZLOCK_BUILD_LOGS_DIR", "") or os.getenv("BEATZLOCK_BUILD_LOGS_DIR", "")
    return Path(configured).expanduser().resolve() if configured else _default_build_logs_dir().resolve()


def _build_log_file(platform_name: str) -> Path:
    return _build_logs_dir() / platform_name / "build_log.json"


def _version_label(entry: dict) -> str:
    version = str(entry.get("version") or "").strip()
    artifact_version = str(entry.get("artifact_version") or "").strip()

    if version:
        return version.split("+", 1)[0]

    if artifact_version:
        parts = artifact_version.split("_", 1)
        return parts[0]

    return "Unknown"


def _build_label(entry: dict) -> str:
    build_number = str(entry.get("build_number") or "").strip()
    if build_number:
        return build_number

    artifact_version = str(entry.get("artifact_version") or "").strip()
    if "_" in artifact_version:
        return artifact_version.split("_", 1)[1]

    return "-"


def _artifact_label(entry: dict) -> str:
    artifact_type = str(entry.get("artifact_type") or "").strip().lower()
    return ARTIFACT_LABELS.get(artifact_type, artifact_type.replace("_", " ").title() or "Unknown")


def _parse_entry_timestamp(value: str):
    parsed = parse_datetime(str(value or "").strip())
    if parsed is not None:
        return parsed

    try:
        return datetime.fromisoformat(str(value or "").strip())
    except ValueError:
        return None


def _load_build_log_entries(platform_name: str) -> list[dict]:
    log_file = _build_log_file(platform_name)
    try:
        payload = json.loads(log_file.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []

    if not isinstance(payload, list):
        return []

    entries = []
    for entry in payload:
        if not isinstance(entry, dict):
            continue

        timestamp_value = _parse_entry_timestamp(entry.get("timestamp", ""))
        sequence_raw = entry.get("sequence", 0)
        try:
            sequence_value = int(sequence_raw)
        except (TypeError, ValueError):
            sequence_value = 0

        normalized = {
            "sequence": sequence_value,
            "platform": platform_name,
            "platform_label": PLATFORM_LABELS.get(platform_name, platform_name.title()),
            "artifact_type": str(entry.get("artifact_type") or "").strip() or "unknown",
            "file": str(entry.get("file") or "").strip(),
            "path": str(entry.get("path") or "").strip(),
            "relative_path": str(entry.get("relative_path") or "").strip(),
            "version": str(entry.get("version") or "").strip(),
            "build_number": str(entry.get("build_number") or "").strip(),
            "artifact_version": str(entry.get("artifact_version") or "").strip(),
            "host_platform": str(entry.get("host_platform") or "").strip(),
            "timestamp": str(entry.get("timestamp") or "").strip(),
            "timestamp_dt": timestamp_value,
            "version_label": "",
            "build_label": "",
            "artifact_label": "",
        }
        normalized["version_label"] = _version_label(normalized)
        normalized["build_label"] = _build_label(normalized)
        normalized["artifact_label"] = _artifact_label(normalized)
        entries.append(normalized)

    entries.sort(
        key=lambda item: (
            item["timestamp_dt"] or datetime.min,
            item["sequence"],
        ),
        reverse=True,
    )
    return entries


def _row_date_key(row: dict) -> str:
    timestamp_dt = row.get("timestamp_dt")
    if timestamp_dt is not None:
        return timestamp_dt.strftime("%Y-%m-%d")
    return str(row.get("timestamp") or "")[:10]


def _display_rows(platform_name: str, entries: list[dict]) -> list[dict]:
    rows = []
    for entry in entries:
        rows.append({
            "platform": platform_name,
            "platform_label": PLATFORM_LABELS.get(platform_name, platform_name.title()),
            "version": entry.get("version_label") or "Unknown",
            "build_number": entry.get("build_label") or "-",
            "artifact_version": entry.get("artifact_version") or "-",
            "artifact": entry.get("artifact_label") or "Unknown",
            "timestamp_dt": entry.get("timestamp_dt"),
            "timestamp": entry.get("timestamp") or "",
            "date_key": "",
        })

    rows.sort(key=lambda item: item["timestamp_dt"] or datetime.min, reverse=True)
    for index, row in enumerate(rows, start=1):
        row["row_number"] = index
        row["date_key"] = _row_date_key(row)
    return rows


def _filter_rows_by_date(rows: list[dict], selected_date: str) -> list[dict]:
    if not selected_date:
        return list(rows)
    return [row for row in rows if row.get("date_key") == selected_date]


def _platform_query(platform_name: str, selected_date: str) -> str:
    params = {"platform": platform_name}
    if selected_date:
        params["date"] = selected_date
    return urlencode(params)


def _platform_summary(platform_name: str, rows: list[dict], selected_date: str) -> dict:
    latest_row = rows[0] if rows else None
    return {
        "platform": platform_name,
        "platform_label": PLATFORM_LABELS.get(platform_name, platform_name.title()),
        "count": len(rows),
        "is_empty": len(rows) == 0,
        "latest_row": latest_row,
        "query_string": _platform_query(platform_name, selected_date),
    }


def _file_summary(platform_name: str, entries: list[dict]) -> dict:
    log_file = _build_log_file(platform_name)
    exists = log_file.exists()
    stat = log_file.stat() if exists else None

    return {
        "platform": platform_name,
        "platform_label": PLATFORM_LABELS.get(platform_name, platform_name.title()),
        "exists": exists,
        "entry_count": len(entries),
        "modified": datetime.fromtimestamp(stat.st_mtime) if stat else None,
    }


@staff_member_required
def build_history(request):
    requested_platform = (request.GET.get("platform") or "").strip().lower()
    selected_date = (request.GET.get("date") or "").strip()
    all_entries_by_platform = {
        platform_name: _load_build_log_entries(platform_name)
        for platform_name in PLATFORMS
    }
    all_display_rows_by_platform = {
        platform_name: _display_rows(platform_name, entries)
        for platform_name, entries in all_entries_by_platform.items()
    }
    display_rows_by_platform = {
        platform_name: _filter_rows_by_date(rows, selected_date)
        for platform_name, rows in all_display_rows_by_platform.items()
    }
    file_summaries = [
        _file_summary(platform_name, all_entries_by_platform[platform_name])
        for platform_name in PLATFORMS
    ]
    platform_summaries = [
        _platform_summary(platform_name, display_rows_by_platform[platform_name], selected_date)
        for platform_name in PLATFORMS
    ]

    selected_platform = requested_platform if requested_platform in PLATFORMS else ""
    if not selected_platform:
        selected_platform = next(
            (summary["platform"] for summary in platform_summaries if summary["count"] > 0),
            "windows",
        )

    selected_platform_label = PLATFORM_LABELS.get(selected_platform, selected_platform.title())
    display_rows = display_rows_by_platform.get(selected_platform, [])
    latest_timestamp = next(
        (row["timestamp_dt"] for row in display_rows if row["timestamp_dt"] is not None),
        None,
    )

    context = {
        "file_summaries": file_summaries,
        "platform_summaries": platform_summaries,
        "entries": display_rows,
        "total_entries": sum(len(rows) for rows in display_rows_by_platform.values()),
        "filtered_entries_count": len(display_rows),
        "latest_timestamp": latest_timestamp,
        "selected_platform": selected_platform,
        "selected_platform_label": selected_platform_label,
        "selected_date": selected_date,
        "missing_files": [summary for summary in file_summaries if not summary["exists"]],
        "has_any_entries": any(summary["count"] > 0 for summary in platform_summaries),
    }
    return render(request, "console/build_history.html", context)
