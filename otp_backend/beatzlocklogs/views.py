import logging
from datetime import datetime
from pathlib import Path

from django.conf import settings
from django.contrib.admin.views.decorators import staff_member_required
from django.http import Http404
from django.shortcuts import render
from django.views.decorators.http import require_http_methods

from otp_backend.logging_config import get_log_files_for_admin

logger = logging.getLogger(__name__)


def _group_logs(log_files: list[dict]) -> list[dict]:
    grouped: dict[tuple[str, str], dict] = {}

    for log in sorted(log_files, key=lambda item: item["modified"], reverse=True):
        key = (log["year"], log["month"])
        if key not in grouped:
            grouped[key] = {
                "year": log["year"],
                "month": log["month"],
                "display": datetime.strptime(
                    f"{log['year']}-{log['month']}", "%Y-%m"
                ).strftime("%B %Y"),
                "logs": [],
            }

        enriched_log = dict(log)
        enriched_log["day"] = log["modified"].strftime("%d")
        grouped[key]["logs"].append(enriched_log)

    return list(grouped.values())


def _safe_log_path(log_file: str) -> Path:
    base_dir = Path(settings.BASE_DIR).resolve()
    log_path = (base_dir / log_file).resolve()

    if base_dir not in log_path.parents and log_path != base_dir:
        raise Http404("Invalid log path")

    if not log_path.exists() or not log_path.is_file():
        raise Http404(f"Log file not found: {log_file}")

    return log_path


def _extract_log_level(line: str) -> str:
    parts = line.split("|", 3)
    if len(parts) < 3:
        return ""
    return parts[1].strip()


def _build_log_entries(lines: list[str]) -> list[dict]:
    entries: list[dict] = []
    current_entry: dict | None = None

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        parts = [part.strip() for part in line.split("|", 3)]

        if len(parts) == 4:
            level = parts[1].upper()
            current_entry = {
                "timestamp": parts[0],
                "level": level,
                "level_class": level.lower() if level in {"ERROR", "WARNING", "INFO", "DEBUG"} else "plain",
                "source": parts[2],
                "message": parts[3],
                "continuation": [],
            }
            entries.append(current_entry)
            continue

        if current_entry is None:
            current_entry = {
                "timestamp": "",
                "level": "LOG",
                "level_class": "plain",
                "source": "",
                "message": line,
                "continuation": [],
            }
            entries.append(current_entry)
            continue

        current_entry["continuation"].append(line)

    return entries


@staff_member_required
@require_http_methods(["GET"])
def log_viewer(request, log_file=None):
    log_files = get_log_files_for_admin()

    date_from = request.GET.get("date_from", "").strip()
    date_to = request.GET.get("date_to", "").strip()
    search = request.GET.get("search", "").strip()

    filtered_logs = list(log_files)

    if date_from:
        try:
            date_from_obj = datetime.strptime(date_from, "%Y-%m-%d").date()
            filtered_logs = [
                log for log in filtered_logs if log["modified"].date() >= date_from_obj
            ]
        except ValueError:
            date_from = ""

    if date_to:
        try:
            date_to_obj = datetime.strptime(date_to, "%Y-%m-%d").date()
            filtered_logs = [
                log for log in filtered_logs if log["modified"].date() <= date_to_obj
            ]
        except ValueError:
            date_to = ""

    if search:
        search_lower = search.lower()
        filtered_logs = [
            log
            for log in filtered_logs
            if search_lower in log["name"].lower()
            or search_lower in log["path"].lower()
        ]

    total_size = sum(log["size"] for log in filtered_logs)
    total_visible_lines = sum(log["line_count"] for log in filtered_logs)
    grouped_logs = _group_logs(filtered_logs)
    latest_modified = max((log["modified"] for log in filtered_logs), default=None)

    context = {
        "grouped_logs": grouped_logs,
        "total_files": len(filtered_logs),
        "total_size": total_size,
        "total_visible_lines": total_visible_lines,
        "total_size_display": _format_size(total_size),
        "latest_modified": latest_modified,
        "date_from": date_from,
        "date_to": date_to,
        "search": search,
        "title": "Application Error Logs",
    }

    if not log_file:
        logger.info(
            "Log viewer accessed by %s with %s files visible",
            request.user.username,
            len(filtered_logs),
        )
        return render(request, "admin/log_viewer.html", context)

    log_path = _safe_log_path(log_file)

    with open(log_path, "r", encoding="utf-8", errors="replace") as file_handle:
        all_lines = file_handle.readlines()

    lines_param = request.GET.get("lines", "500").strip()
    search_text = request.GET.get("search_text", "").strip()
    level_filter = request.GET.get("level", "").strip().upper()

    try:
        lines = int(lines_param)
    except ValueError:
        lines = 500

    filtered_lines = all_lines

    if search_text:
        search_text_lower = search_text.lower()
        filtered_lines = [
            line for line in filtered_lines if search_text_lower in line.lower()
        ]

    if level_filter:
        filtered_lines = [
            line for line in filtered_lines if _extract_log_level(line) == level_filter
        ]

    displayed_lines = filtered_lines[-lines:] if lines > 0 else filtered_lines
    log_entries = _build_log_entries(displayed_lines)

    detail_context = {
        "log_file": log_file,
        "log_name": log_path.name,
        "log_lines": displayed_lines,
        "log_entries": log_entries,
        "total_lines": len(all_lines),
        "filtered_lines": len(filtered_lines),
        "displayed_lines": len(displayed_lines),
        "displayed_entries": len(log_entries),
        "search_text": search_text,
        "level_filter": level_filter,
        "lines": lines,
        "file_size": log_path.stat().st_size,
        "file_size_display": _format_size(log_path.stat().st_size),
        "modified": datetime.fromtimestamp(log_path.stat().st_mtime),
        "error_count": sum(1 for line in filtered_lines if "ERROR" in line),
        "warning_count": sum(1 for line in filtered_lines if "WARNING" in line),
        "info_count": sum(1 for line in filtered_lines if "INFO" in line),
        "title": f"Error Log - {log_path.name}",
    }

    return render(request, "admin/log_detail.html", detail_context)


def _format_size(size: int) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"
