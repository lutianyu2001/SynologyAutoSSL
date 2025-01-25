#!/usr/bin/env python3

import json
import sys
import shutil
import logging
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple

# Pre-defined parameters
CERT_FILES = ("cert.pem", "privkey.pem", "fullchain.pem")
BASE_PATH = Path("/usr/syno/etc/certificate")
PKG_BASE_PATH = Path("/usr/local/etc/certificate") 
ARCHIVE_PATH = BASE_PATH / "_archive"

# log colors
COLORS = {
    "INFO": "\033[0;32m",
    "WARN": "\033[1;33m", 
    "ERROR": "\033[1;31m",
    "NC": "\033[0m"
}

def setup_logging():
    """Configure logging with custom formatter for colored console output."""
    class ConsoleFormatter(logging.Formatter):
        def format(self, record):
            timestamp = datetime.fromtimestamp(record.created).strftime("[%a %b %d %I:%M:%S %p %Z %Y]")
            color = COLORS.get(record.levelname, COLORS["NC"])
            return f"{timestamp} {color}[{record.levelname}]{COLORS['NC']} {record.getMessage()}"
            
    handler = logging.StreamHandler()
    handler.setFormatter(ConsoleFormatter())
    logging.root.addHandler(handler)
    logging.root.setLevel(logging.INFO)

def copy_certificates(src_dir: Path, service: Dict) -> bool:
    """
    Copy certificate files for a service.
    
    Args:
        src_dir: Source directory containing certificates
        service: Service configuration dictionary
    
    Returns:
        bool: True if all certificates copied successfully, False otherwise
    """
    log = logging.getLogger(__name__)
    target_dir = (PKG_BASE_PATH if service["isPkg"] else BASE_PATH) / service["subscriber"] / service["service"]
    target_dir.mkdir(parents=True, exist_ok=True)
    
    log.info(f"Copy cert for {service['display_name']}")
    success = True

    for cert_file in CERT_FILES:
        src, dest = src_dir / cert_file, target_dir / cert_file
        try:
            shutil.copy2(src, dest)
        except Exception as e:
            log.warning(f"copy from {src} to {dest} fail: {e}")
            success = False

    return success

def load_service_info(archive_path: Path, src_dir_name: str) -> Tuple[List[Dict], bool]:
    """
    Load and validate service information from INFO file.
    
    Args:
        archive_path: Path to archive directory
        src_dir_name: Name of source directory
        
    Returns:
        Tuple containing list of service configurations and success status
    """
    log = logging.getLogger(__name__)
    
    try:
        services = json.loads((archive_path / "INFO").read_text())
        
        if src_dir_name not in services:
            log.error(f"Source directory {src_dir_name} not found in INFO file")
            return [], False
            
        return services[src_dir_name]["services"], True
        
    except FileNotFoundError:
        log.error(f"load INFO file- {archive_path/'INFO'} fail: File not found")
    except json.JSONDecodeError:
        log.error(f"load INFO file- {archive_path/'INFO'} fail: Invalid JSON")
    except Exception as e:
        log.error(f"load INFO file- {archive_path/'INFO'} fail: {e}")
    
    return [], False

def process_certificates(src_dir_name: str) -> bool:
    """
    Process certificates for all services.
    
    Args:
        src_dir_name: Name of source directory
        
    Returns:
        bool: True if all services processed successfully, False otherwise
    """
    src_dir = ARCHIVE_PATH / src_dir_name
    services, success = load_service_info(ARCHIVE_PATH, src_dir_name)
    
    if not success:
        return False
        
    return all(copy_certificates(src_dir, service) for service in services)

def main():
    if len(sys.argv) != 2:
        print("Usage: crt_cp.py <certificate_source_directory>", file=sys.stderr)
        sys.exit(1)

    setup_logging()
    sys.exit(0 if process_certificates(sys.argv[1]) else 1)

if __name__ == "__main__":
    main()
