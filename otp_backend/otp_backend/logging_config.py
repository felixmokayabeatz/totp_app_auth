import os
import logging
from logging.handlers import TimedRotatingFileHandler
from datetime import datetime
from pathlib import Path

# Create logs directory structure
BASE_DIR = Path(__file__).resolve().parent.parent
LOGS_DIR = BASE_DIR / 'logs'

def get_log_path(filename_prefix):
    """Get log file path with year/month organization"""
    current_date = datetime.now()
    year = current_date.strftime('%Y')
    month = current_date.strftime('%m')
    day = current_date.strftime('%Y-%m-%d')
    
    # Create year/month directory
    log_dir = LOGS_DIR / year / month
    log_dir.mkdir(parents=True, exist_ok=True)
    
    # Return full file path
    return log_dir / f"{filename_prefix}_{day}.log"

def get_log_files_for_admin():
    """Get all log files organized by year/month"""
    log_files = []
    
    if LOGS_DIR.exists():
        # Get all year directories
        for year_dir in sorted(LOGS_DIR.iterdir(), reverse=True):
            if year_dir.is_dir() and year_dir.name.isdigit():
                # Get all month directories
                for month_dir in sorted(year_dir.iterdir(), reverse=True):
                    if month_dir.is_dir() and month_dir.name.isdigit():
                        # Get all log files in this month
                        for log_file in sorted(month_dir.glob('*.log'), reverse=True):
                            # Get file stats
                            stat = log_file.stat()
                            # Create relative path for URL
                            rel_path = log_file.relative_to(BASE_DIR)
                            
                            log_files.append({
                                'path': str(rel_path).replace('\\', '/'),
                                'name': log_file.name,
                                'size': stat.st_size,
                                'size_display': format_size(stat.st_size),
                                'modified': datetime.fromtimestamp(stat.st_mtime),
                                'year': year_dir.name,
                                'month': month_dir.name,
                                'type': get_log_type(log_file.name),
                                'line_count': count_lines(log_file)
                            })
    
    return log_files

def format_size(size):
    """Format file size nicely"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"

def get_log_type(filename):
    """Get log type from filename"""
    if 'error' in filename.lower():
        return 'error'
    elif 'warning' in filename.lower():
        return 'warning'
    elif 'api' in filename.lower():
        return 'api'
    elif 'twofa' in filename.lower():
        return '2fa'
    elif 'sync' in filename.lower():
        return 'sync'
    else:
        return 'info'

def count_lines(filepath):
    """Count lines in file efficiently"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return sum(1 for _ in f)
    except:
        return 0

class DailyRotatingFileHandler(logging.Handler):
    """Custom handler that creates daily log files in year/month folders"""
    
    def __init__(self, filename_prefix, level=logging.NOTSET):
        super().__init__(level)
        self.filename_prefix = filename_prefix
        self.current_date = None
        self.handler = None
        self._create_handler()
    
    def _create_handler(self):
        """Create or recreate the file handler"""
        current_date = datetime.now().date()
        
        # If date changed, recreate handler
        if self.current_date != current_date:
            if self.handler:
                self.handler.close()
            
            # Create new log file path
            year = datetime.now().strftime('%Y')
            month = datetime.now().strftime('%m')
            day = datetime.now().strftime('%Y-%m-%d')
            
            log_dir = LOGS_DIR / year / month
            log_dir.mkdir(parents=True, exist_ok=True)
            
            log_file = log_dir / f"{self.filename_prefix}_{day}.log"
            
            # Create new handler
            self.handler = logging.FileHandler(log_file, encoding='utf-8')
            self.handler.setFormatter(self.formatter)
            self.current_date = current_date
    
    def setFormatter(self, formatter):
        """Set formatter on handler"""
        super().setFormatter(formatter)
        if self.handler:
            self.handler.setFormatter(formatter)
    
    def emit(self, record):
        """Emit log record"""
        self._create_handler()
        if self.handler:
            self.handler.emit(record)
    
    def close(self):
        """Close handler"""
        if self.handler:
            self.handler.close()
        super().close()

def get_logging_config(debug_mode):
    """Return logging configuration dictionary"""
    
    # Create formatters
    detailed_formatter = logging.Formatter(
        '[%(asctime)s] %(levelname)s [%(name)s:%(lineno)d] - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    simple_formatter = logging.Formatter(
        '[%(asctime)s] %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    config = {
        'version': 1,
        'disable_existing_loggers': False,
        'formatters': {
            'detailed': {
                'format': '[%(asctime)s] %(levelname)s [%(name)s:%(lineno)d] - %(message)s',
                'datefmt': '%Y-%m-%d %H:%M:%S'
            },
            'simple': {
                'format': '[%(asctime)s] %(levelname)s - %(message)s',
                'datefmt': '%Y-%m-%d %H:%M:%S'
            },
        },
        'filters': {
            'require_debug_true': {
                '()': 'django.utils.log.RequireDebugTrue',
            },
        },
        'handlers': {
            'console': {
                'class': 'logging.StreamHandler',
                'formatter': 'detailed',
                'level': 'DEBUG',
                'filters': ['require_debug_true'],
            },
            'error_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'errors',
                'formatter': 'detailed',
                'level': 'ERROR',
            },
            'warning_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'warnings',
                'formatter': 'detailed',
                'level': 'WARNING',
            },
            'info_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'info',
                'formatter': 'detailed',
                'level': 'INFO',
            },
            'api_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'api',
                'formatter': 'detailed',
                'level': 'INFO',
            },
            'twofa_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'twofa',
                'formatter': 'detailed',
                'level': 'INFO',
            },
            'sync_file': {
                '()': DailyRotatingFileHandler,
                'filename_prefix': 'sync',
                'formatter': 'detailed',
                'level': 'INFO',
            },
        },
        'loggers': {
            'django': {
                'handlers': ['console', 'error_file', 'warning_file', 'info_file'],
                'level': 'INFO',
                'propagate': True,
            },
            'django.request': {
                'handlers': ['error_file', 'warning_file'],
                'level': 'ERROR',
                'propagate': False,
            },
            'api': {
                'handlers': ['console', 'api_file', 'error_file', 'warning_file'],
                'level': 'DEBUG' if debug_mode else 'INFO',
                'propagate': False,
            },
            'twofa': {
                'handlers': ['console', 'twofa_file', 'error_file', 'warning_file'],
                'level': 'DEBUG' if debug_mode else 'INFO',
                'propagate': False,
            },
            'accounts': {
                'handlers': ['console', 'error_file', 'warning_file'],
                'level': 'DEBUG' if debug_mode else 'INFO',
                'propagate': False,
            },
            'sync': {
                'handlers': ['console', 'sync_file', 'error_file', 'warning_file'],
                'level': 'DEBUG' if debug_mode else 'INFO',
                'propagate': False,
            },
        },
        'root': {
            'handlers': ['console', 'error_file', 'warning_file'],
            'level': 'WARNING',
        },
    }
    
    return config