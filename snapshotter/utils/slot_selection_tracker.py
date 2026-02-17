"""
Simple tracker for slot selection status.

This module provides a minimal file-based mechanism for compute packages to report
slot selection decisions to the lite node, enabling selection-aware health monitoring.
"""

import json
import time
from pathlib import Path
from typing import Optional


class SlotSelectionTracker:
    """
    Tracks slot selection status using file-based persistence.
    
    This tracker allows compute packages to report whether a slot was selected
    for processing in a given epoch, enabling the health monitoring system to
    distinguish between legitimate non-selection and actual failures.
    """
    
    def __init__(self, status_file: str = 'slot_selection_status.txt'):
        """
        Initialize the tracker.
        
        Args:
            status_file: Path to the status file (default: slot_selection_status.txt)
        """
        self._status_file = Path(status_file)
    
    def report_selection(self, epoch_id: int, was_selected: bool, slot_id: int) -> None:
        """
        Report slot selection status for an epoch.
        
        This method is called by compute packages to report whether their slot
        was selected for processing in a given epoch. The status is written
        synchronously to ensure availability for health checks.
        
        Args:
            epoch_id: The epoch ID
            was_selected: True if slot was selected, False otherwise
            slot_id: The slot ID that was checked
        """
        status = {
            'epoch_id': epoch_id,
            'was_selected': was_selected,
            'slot_id': slot_id,
            'timestamp': int(time.time())
        }
        
        try:
            with open(self._status_file, 'w') as f:
                json.dump(status, f)
        except Exception as e:
            # Log error but don't raise - don't want to break compute flow
            print(f"Error writing slot selection status: {e}")
    
    def get_last_selection(self) -> Optional[dict]:
        """
        Read the last reported selection status.
        
        Returns:
            Dict with keys: epoch_id, was_selected, slot_id, timestamp
            None if file doesn't exist or can't be read
        """
        if not self._status_file.exists():
            return None
        
        try:
            with open(self._status_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            print(f"Error reading slot selection status: {e}")
            return None
