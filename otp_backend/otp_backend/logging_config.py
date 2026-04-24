import logging
import re
from datetime import datetime
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent
LOGS_DIR = BASE_DIR / "logs"


def get_log_files_for_admin():
    """Return only error log files for the admin log viewer."""
    log_files = []

    if not LOGS_DIR.exists():
        return log_files

    for year_dir in sorted(LOGS_DIR.iterdir(), reverse=True):
        if not year_dir.is_dir() or not year_dir.name.isdigit():
            continue

        for month_dir in sorted(year_dir.iterdir(), reverse=True):
            if not month_dir.is_dir() or not month_dir.name.isdigit():
                continue

            for log_file in sorted(month_dir.glob("errors_*.log"), reverse=True):
                stat = log_file.stat()
                rel_path = log_file.relative_to(BASE_DIR)
                log_files.append(
                    {
                        "path": str(rel_path).replace("\\", "/"),
                        "name": log_file.name,
                        "size": stat.st_size,
                        "size_display": format_size(stat.st_size),
                        "modified": datetime.fromtimestamp(stat.st_mtime),
                        "year": year_dir.name,
                        "month": month_dir.name,
                        "type": "error",
                        "line_count": count_lines(log_file),
                    }
                )

    return log_files


def format_size(size):
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"


def count_lines(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as file_handle:
            return sum(1 for _ in file_handle)
    except OSError:
        return 0


class RedactingFormatter(logging.Formatter):
    """Strip sensitive values from error logs."""

    EMAIL_RE = re.compile(r"[\w.\-+%]+@[\w.\-]+\.[A-Za-z]{2,}")
    IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
    KEY_VALUE_RE = re.compile(
        r"\b(User|Username|Email|IP|Code|Device|Account ID)\s*:\s*([^\s,\]]+)",
        re.IGNORECASE,
    )

    def format(self, record):
        original_msg = record.msg
        original_args = record.args
        original_exc = record.exc_info

        try:
            rendered = record.getMessage()
            record.msg = self._redact(rendered)
            record.args = ()

            if original_exc:
                exc_text = self.formatException(original_exc)
                redacted_exc = self._redact(exc_text)
                formatted = super().format(record)
                return f"{formatted}\n{redacted_exc}"

            return super().format(record)
        finally:
            record.msg = original_msg
            record.args = original_args
            record.exc_info = original_exc

    def _redact(self, value):
        value = self.EMAIL_RE.sub("[redacted-email]", value)
        value = self.IPV4_RE.sub("[redacted-ip]", value)
        value = self.KEY_VALUE_RE.sub(lambda m: f"{m.group(1)}: [redacted]", value)
        return value


class DailyRotatingFileHandler(logging.Handler):
    """Create a daily error log file under logs/YYYY/MM/."""

    def __init__(self, filename_prefix, level=logging.NOTSET):
        super().__init__(level)
        self.filename_prefix = filename_prefix
        self.current_date = None
        self.handler = None
        self._create_handler()

    def _create_handler(self):
        current_date = datetime.now().date()
        if self.current_date == current_date:
            return

        if self.handler:
            self.handler.close()

        year = datetime.now().strftime("%Y")
        month = datetime.now().strftime("%m")
        day = datetime.now().strftime("%Y-%m-%d")

        log_dir = LOGS_DIR / year / month
        log_dir.mkdir(parents=True, exist_ok=True)

        log_file = log_dir / f"{self.filename_prefix}_{day}.log"
        self.handler = logging.FileHandler(log_file, encoding="utf-8")
        if self.formatter:
            self.handler.setFormatter(self.formatter)
        self.current_date = current_date

    def setFormatter(self, formatter):
        super().setFormatter(formatter)
        if self.handler:
            self.handler.setFormatter(formatter)

    def emit(self, record):
        self._create_handler()
        if self.handler:
            self.handler.emit(record)

    def close(self):
        if self.handler:
            self.handler.close()
        super().close()


def get_logging_config(debug_mode):
    del debug_mode

    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "redacted_detailed": {
                "()": RedactingFormatter,
                "format": "[%(asctime)s] %(levelname)s [%(name)s:%(lineno)d] - %(message)s",
                "datefmt": "%Y-%m-%d %H:%M:%S",
            },
        },
        "handlers": {
            "error_file": {
                "()": DailyRotatingFileHandler,
                "filename_prefix": "errors",
                "formatter": "redacted_detailed",
                "level": "ERROR",
            },
            "console": {
                "class": "logging.StreamHandler",
            },
        },
        "loggers": {
            "django": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
            "django.request": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
            "django.server": {
                "handlers": ["console"],
                "level": "INFO",
                "propagate": False,
            },
            "api": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
            "twofa": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
            "accounts": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
            "beatzlocklogs": {
                "handlers": ["error_file", "console"],
                "level": "ERROR",
                "propagate": False,
            },
        },
        "root": {
            "handlers": ["error_file", "console"],
            "level": "ERROR",
        },
    }