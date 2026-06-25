from core.queue_status import queue_ui_state


def test_running():
    assert queue_ui_state(queue_paused=False, running=True) == "running"


def test_pausing_is_paused_flag_while_still_running():
    assert queue_ui_state(queue_paused=True, running=True) == "pausing"


def test_paused_after_drain():
    assert queue_ui_state(queue_paused=True, running=False) == "paused"


def test_idle():
    assert queue_ui_state(queue_paused=False, running=False) == "idle"
