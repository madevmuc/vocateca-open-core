"""Reusable empty-state widget (roadmap 9.3).

A centred icon/title/hint (+ optional primary action button) shown when a tab's
backing model is empty. Theme-token styled so it reads correctly in light + dark
— no hard-coded colours.
"""

from __future__ import annotations

from typing import Callable

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QLabel, QPushButton, QVBoxLayout, QWidget


class EmptyState(QWidget):
    def __init__(
        self,
        *,
        title: str,
        hint: str,
        action_text: str | None = None,
        on_action: Callable[[], None] | None = None,
        icon: str = "",
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        from ui.themes import current_tokens

        t = current_tokens()
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.setSpacing(8)

        if icon:
            icon_label = QLabel(icon)
            icon_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            icon_label.setStyleSheet("font-size: 40px;")
            layout.addWidget(icon_label)

        self.title_label = QLabel(title)
        self.title_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.title_label.setStyleSheet(f"color: {t['ink']}; font-size: 16px; font-weight: 600;")
        layout.addWidget(self.title_label)

        self.hint_label = QLabel(hint)
        self.hint_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.hint_label.setWordWrap(True)
        self.hint_label.setStyleSheet(f"color: {t['ink_3']}; font-size: 12px;")
        layout.addWidget(self.hint_label)

        self.action_btn: QPushButton | None = None
        if action_text and on_action is not None:
            self.action_btn = QPushButton(action_text)
            self.action_btn.clicked.connect(lambda: on_action())
            btn_row = QWidget()
            row = QVBoxLayout(btn_row)
            row.setAlignment(Qt.AlignmentFlag.AlignCenter)
            row.addWidget(self.action_btn)
            layout.addWidget(btn_row)
