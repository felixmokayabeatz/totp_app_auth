import logging
from datetime import datetime
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent
LOGS_DIR = BASE_DIR / "logs"


def get_log_files_for_admin():
    """Return available error log files for the admin viewer."""
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
            "detailed": {
                "format": "%(asctime)s | %(levelname)-8s | %(name)s:%(lineno)d | %(message)s",
                "datefmt": "%Y-%m-%d %H:%M:%S",
            },
        },
        "handlers": {
            "error_file": {
                "()": DailyRotatingFileHandler,
                "filename_prefix": "errors",
                "formatter": "detailed",
                "level": "ERROR",
            },
            "console": {
                "class": "logging.StreamHandler",
                "formatter": "detailed",
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
            "django.security": {
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
