#!/usr/bin/env python3
"""
TUI Box Generator and Validator

Generates correctly aligned TUI boxes and validates rendered output.
Can be used for:
1. Generating examples for documentation
2. Testing that the real application renders correctly
3. Validating box dimensions mathematically

Usage:
    # Generate a box
    python3 tui_box_generator.py generate --content "Hello" --width 70

    # Validate a rendered box from file
    python3 tui_box_generator.py validate rendered_output.txt --expected-width 76

    # Generate all documentation examples
    python3 tui_box_generator.py generate-docs
"""

import sys
import argparse
from typing import List, Tuple, Optional
import re

try:
    from wcwidth import wcswidth
    HAS_WCWIDTH = True
except ImportError:
    HAS_WCWIDTH = False
    print("WARNING: wcwidth not installed. Emoji width calculation may be incorrect.", file=sys.stderr)
    print("Install with: pip install wcwidth", file=sys.stderr)


class TUIBox:
    """Represents a TUI box with proper dimension calculations."""

    def __init__(
        self,
        content_width: int = 70,
        padding_left: int = 2,
        padding_right: int = 2,
        padding_top: int = 0,
        padding_bottom: int = 0,
        border_width: int = 1,
        margin_left: int = 0,
        margin_right: int = 0,
        margin_top: int = 0,
        margin_bottom: int = 0,
    ):
        self.content_width = content_width
        self.padding_left = padding_left
        self.padding_right = padding_right
        self.padding_top = padding_top
        self.padding_bottom = padding_bottom
        self.border_width = border_width
        self.margin_left = margin_left
        self.margin_right = margin_right
        self.margin_top = margin_top
        self.margin_bottom = margin_bottom

    def calculate_dimensions(self) -> Tuple[int, int]:
        """Calculate total width and height frame size."""
        h_frame = (
            self.margin_left
            + self.border_width
            + self.padding_left
            + self.padding_right
            + self.border_width
            + self.margin_right
        )

        v_frame = (
            self.margin_top
            + self.border_width
            + self.padding_top
            + self.padding_bottom
            + self.border_width
            + self.margin_bottom
        )

        return h_frame, v_frame

    def get_total_width(self) -> int:
        """Get total width including all frame components."""
        h_frame, _ = self.calculate_dimensions()
        return self.content_width + h_frame

    def get_interior_width(self) -> int:
        """Get interior width (between borders)."""
        return self.padding_left + self.content_width + self.padding_right

    def get_visual_width(self, text: str) -> int:
        """
        Calculate visual width of text, ignoring ANSI escape codes.

        Properly handles:
        - ANSI escape sequences (ignored)
        - Unicode wide characters (CJK, emoji = 2 cols)
        - Combining characters (0 cols)
        """
        # Remove ANSI escape codes
        ansi_pattern = re.compile(r'\x1b\[[0-9;]*m')
        clean_text = ansi_pattern.sub('', text)

        # Use wcwidth if available for accurate emoji/CJK width
        if HAS_WCWIDTH:
            width = wcswidth(clean_text)
            # wcswidth returns -1 if string contains control characters
            if width >= 0:
                return width

        # Fallback to simple length (less accurate for emoji)
        return len(clean_text)

    def render(self, lines: List[str], alignment: str = "left") -> List[str]:
        """
        Render a box with the given content lines.

        Args:
            lines: List of content lines
            alignment: 'left', 'center', or 'right'

        Returns:
            List of rendered lines with correct dimensions
        """
        result = []
        interior_width = self.get_interior_width()

        # Margin top
        for _ in range(self.margin_top):
            result.append("")

        # Top border
        if self.border_width > 0:
            margin = " " * self.margin_left
            border_line = margin + "┌" + ("─" * interior_width) + "┐"
            result.append(border_line)

        # Padding top
        for _ in range(self.padding_top):
            result.append(self._render_empty_line())

        # Content lines
        for line in lines:
            result.append(self._render_content_line(line, alignment))

        # Padding bottom
        for _ in range(self.padding_bottom):
            result.append(self._render_empty_line())

        # Bottom border
        if self.border_width > 0:
            margin = " " * self.margin_left
            border_line = margin + "└" + ("─" * interior_width) + "┘"
            result.append(border_line)

        # Margin bottom
        for _ in range(self.margin_bottom):
            result.append("")

        return result

    def _render_empty_line(self) -> str:
        """Render an empty line (padding line)."""
        interior_width = self.get_interior_width()
        margin = " " * self.margin_left

        if self.border_width > 0:
            return margin + "│" + (" " * interior_width) + "│"
        else:
            return " " * (self.margin_left + interior_width + self.margin_right)

    def _render_content_line(self, content: str, alignment: str = "left") -> str:
        """Render a content line with proper padding and alignment."""
        visual_width = self.get_visual_width(content)
        content_padding = self.content_width - visual_width

        # Apply alignment
        if alignment == "center":
            left_pad = content_padding // 2
            right_pad = content_padding - left_pad
            aligned_content = (" " * left_pad) + content + (" " * right_pad)
        elif alignment == "right":
            aligned_content = (" " * content_padding) + content
        else:  # left
            aligned_content = content + (" " * content_padding)

        margin = " " * self.margin_left
        padding_left = " " * self.padding_left
        padding_right = " " * self.padding_right

        if self.border_width > 0:
            return margin + "│" + padding_left + aligned_content + padding_right + "│"
        else:
            return margin + padding_left + aligned_content + padding_right

    def print_dimensions(self):
        """Print box dimensions for debugging."""
        h_frame, v_frame = self.calculate_dimensions()
        total_width = self.get_total_width()
        interior_width = self.get_interior_width()

        print(f"Box Dimensions:")
        print(f"  Content:  {self.content_width}")
        print(f"  Padding:  L={self.padding_left} R={self.padding_right} " +
              f"T={self.padding_top} B={self.padding_bottom}")
        print(f"  Border:   {self.border_width}")
        print(f"  Margin:   L={self.margin_left} R={self.margin_right} " +
              f"T={self.margin_top} B={self.margin_bottom}")
        print(f"  Interior: {interior_width}")
        print(f"  H Frame:  {h_frame}")
        print(f"  V Frame:  {v_frame}")
        print(f"  Total:    {total_width}")


def validate_box(lines: List[str], expected_width: Optional[int] = None) -> bool:
    """
    Validate that a rendered box has correct dimensions.

    Args:
        lines: Rendered box lines
        expected_width: Expected width (if None, uses first line width)

    Returns:
        True if valid, False otherwise
    """
    if not lines:
        print("❌ ERROR: No lines to validate")
        return False

    # Helper to get visual width
    def get_width(text: str) -> int:
        if HAS_WCWIDTH:
            width = wcswidth(text)
            if width >= 0:
                return width
        return len(text)

    # Get expected width from first line if not specified
    if expected_width is None:
        expected_width = get_width(lines[0])

    all_valid = True
    for i, line in enumerate(lines):
        actual_width = get_width(line)
        if actual_width != expected_width:
            print(f"❌ Line {i+1}: Expected {expected_width} chars, got {actual_width}")
            print(f"   Content: '{line}'")
            print(f"   Python len: {len(line)}, Visual width: {actual_width}")
            all_valid = False

    if all_valid:
        print(f"✅ All {len(lines)} lines have correct width: {expected_width} visual columns")

    return all_valid


def generate_example(name: str, config: dict, lines: List[str]) -> str:
    """Generate a named example with calculation details."""
    box = TUIBox(**config)
    rendered = box.render(lines)

    h_frame, v_frame = box.calculate_dimensions()
    total_width = box.get_total_width()
    interior_width = box.get_interior_width()

    output = []
    output.append(f"### {name}")
    output.append("")
    output.append("**Configuración:**")
    output.append(f"- Content width: {box.content_width}")
    output.append(f"- Padding: left={box.padding_left}, right={box.padding_right}, " +
                 f"top={box.padding_top}, bottom={box.padding_bottom}")
    output.append(f"- Border: {box.border_width}")
    output.append("")
    output.append("**Cálculo:**")
    output.append("```")
    output.append(f"content_width = {box.content_width}")
    output.append(f"interior_width = padding_left({box.padding_left}) + " +
                 f"content({box.content_width}) + padding_right({box.padding_right}) = {interior_width}")
    output.append(f"h_frame = border({box.border_width}) + padding_left({box.padding_left}) + " +
                 f"padding_right({box.padding_right}) + border({box.border_width}) = {h_frame}")
    output.append(f"total_width = content_width({box.content_width}) + h_frame({h_frame}) = {total_width}")
    output.append("```")
    output.append("")
    output.append(f"**Render ({total_width} columnas × {len(rendered)} líneas):**")
    output.append("")
    output.append("```")
    for line in rendered:
        output.append(line)
    output.append("```")
    output.append("")
    output.append("**Verificación:**")
    output.append("```")
    if validate_box(rendered, total_width):
        output.append(f"✓ Todas las líneas tienen {total_width} caracteres")
    else:
        output.append("✗ ERROR: Dimensiones incorrectas")
    output.append("```")
    output.append("")

    return "\n".join(output)


def generate_all_examples():
    """Generate all documentation examples."""

    print("=" * 80)
    print("GENERANDO EJEMPLOS PARA DOCUMENTACIÓN")
    print("=" * 80)
    print()

    # Example 1: Main Menu (Standard)
    example1 = generate_example(
        "Ejemplo 1: Menú Principal (Estándar wayu)",
        {"content_width": 70, "padding_left": 2, "padding_right": 2},
        [
            "wayu v3.0 - Shell Configuration Manager                          [zsh]",
            "",
            "Main Menu",
            "",
            "📂  PATH Management          Manage PATH entries (12 entries)",
            "",
            "🔑  Aliases                  Shell aliases (8 defined)",
            "",
            "💾  Constants                Environment variables (5 defined)",
            "",
            "⚡  Completions              Zsh completions (3 installed)",
            "",
            "💿  Backups                  Configuration backups (2 available)",
            "",
            "🔌  Plugins                  Shell plugins (0 installed)",
            "",
            "⚙   Settings                 Shell detection & preferences",
        ]
    )
    print(example1)

    # Example 2: PATH View
    example2 = generate_example(
        "Ejemplo 2: Vista de PATH",
        {"content_width": 70, "padding_left": 2, "padding_right": 2},
        [
            "PATH Management                                       12 entries  📂",
            "",
            "✓  /usr/local/bin                                    [exists]",
            "✓  /usr/bin                                          [exists]",
            "✓  /bin                                              [exists]",
            "✓  /usr/sbin                                         [exists]",
            "✗  /opt/homebrew/bin                                 [missing]",
            "✓  $HOME/.local/bin                                  [exists]",
            "⚠  /usr/local/bin                                    [duplicate]",
            "",
            "Actions:",
            "  • a - Add new PATH entry",
            "  • d - Remove entry (interactive)",
            "  • c - Clean duplicates",
        ]
    )
    print(example2)

    # Example 3: Simple Box (for algorithm documentation)
    example3 = generate_example(
        "Ejemplo 3: Caja Simple (Sin Padding)",
        {"content_width": 11, "padding_left": 0, "padding_right": 0},
        ["Hello World"]
    )
    print(example3)

    # Example 4: Box with Padding
    example4 = generate_example(
        "Ejemplo 4: Caja con Padding",
        {"content_width": 2, "padding_left": 2, "padding_right": 2,
         "padding_top": 1, "padding_bottom": 1},
        ["Hi"]
    )
    print(example4)

    # Example 5: Footer/Status Bar
    example5 = generate_example(
        "Ejemplo 5: Barra de Estado (Footer)",
        {"content_width": 70, "padding_left": 2, "padding_right": 2},
        ["⌨  j/k or ↑↓ Navigate  •  Enter Select  •  q Quit  •  ? Help"]
    )
    print(example5)


def main():
    parser = argparse.ArgumentParser(
        description="TUI Box Generator and Validator"
    )
    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # Generate command
    gen_parser = subparsers.add_parser("generate", help="Generate a box")
    gen_parser.add_argument("--content", nargs="+", help="Content lines")
    gen_parser.add_argument("--width", type=int, default=70, help="Content width")
    gen_parser.add_argument("--padding", type=int, default=2, help="Padding (all sides)")
    gen_parser.add_argument("--alignment", choices=["left", "center", "right"],
                           default="left", help="Content alignment")

    # Validate command
    val_parser = subparsers.add_parser("validate", help="Validate a rendered box")
    val_parser.add_argument("file", help="File containing rendered box")
    val_parser.add_argument("--expected-width", type=int, help="Expected width")

    # Generate docs command
    subparsers.add_parser("generate-docs", help="Generate all documentation examples")

    args = parser.parse_args()

    if args.command == "generate":
        content = args.content if args.content else ["Example content"]
        box = TUIBox(
            content_width=args.width,
            padding_left=args.padding,
            padding_right=args.padding
        )

        print("Box Configuration:")
        box.print_dimensions()
        print()

        rendered = box.render(content, args.alignment)
        print("Rendered Box:")
        for i, line in enumerate(rendered):
            print(f"{i+1}: ({len(line):3d}) {line}")

        print()
        validate_box(rendered)

    elif args.command == "validate":
        with open(args.file, 'r') as f:
            lines = [line.rstrip('\n') for line in f.readlines()]

        validate_box(lines, args.expected_width)

    elif args.command == "generate-docs":
        generate_all_examples()

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
