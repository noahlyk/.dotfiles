from fontTools.ttLib import TTLibFileIsCollectionError, TTFont
import sys
import subprocess
from typing import List, Tuple
from multiprocessing import Pool


class Font:
    def __init__(self, path: str, name: str):
        self.path = path
        self.name = name

    def __repr__(self):
        return f"Path: {self.path}, Name: {self.name}"


def get_fonts() -> List[Font]:
    result = subprocess.run(["fc-list"], capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    fonts = []
    for line in lines:
        if ": " in line:
            parts = line.split(": ", 1)
            font_path = parts[0].strip()
            font_name = parts[1].strip().split(",")[0].split(":")[0]
            fonts.append(Font(font_path, font_name))
    return fonts


font_cache = {}


def char_exists_in_font(font_path, chars):
    cache_key = f"{font_path}-{chars}"
    if cache_key in font_cache:
        return font_cache[cache_key]
    try:
        font = TTFont(font_path)
    except TTLibFileIsCollectionError as e:
        num_fonts = int(str(e).split("and ")[1].split(" ")[0])
        for font_number in range(num_fonts + 1):
            font = TTFont(font_path, fontNumber=font_number)
            if check_char_in_font(font, chars):
                font_cache[cache_key] = True
                return True
        font_cache[cache_key] = False
        return False
    else:
        result = check_char_in_font(font, chars)
        font_cache[cache_key] = result
        return result


def check_char_in_font(font, chars):
    for table in font['cmap'].tables:
        if ord(chars) in table.cmap:
            return True
    return False


def check_fonts_for_char(char) -> Tuple[str, List[str]]:
    matching_fonts = []
    for font in fonts:
        if char_exists_in_font(font.path, char):
            matching_fonts.append(font.name)
    return char, matching_fonts


if __name__ == "__main__":
    chars = "🐍✘一" + "".join(sys.argv[1:])
    fonts = get_fonts()
    with Pool() as pool:
        results: List[Tuple[str, List[str]]] = pool.map(
            check_fonts_for_char, chars)

    for char, matching_fonts in results:
        print(f"{char}\n  {' '.join(matching_fonts)}")
