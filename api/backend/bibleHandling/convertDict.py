import json
import fitz
import pandas as pd
import spacy
import os

nlp = spacy.load("en_core_web_sm")
main_path = "/Users/jaceysimpson/Vscode/FellowScript/"

def log_results(func):
    def wrapper(self, *args, **kwargs):
        print(f"beginning {func.__name__} \n")
        result = func(self, *args, **kwargs)
        with open(self.log_path, 'a') as f:
            f.write(f"{func.__name__} --> {result}\n")
        print(f"saved result to log path\n")
        return result
    return wrapper
        
class ConvertBibleToDict:
    def __init__(
            self, 
            dict_path="data/bible.json", 
            pdf_path="data/ESV Bible.pdf",
            log_path="data/bible_logs.txt",
            bible_version="esv",
            ):
        self.out_file = os.path.join(main_path, f"data/list_{bible_version}.csv")
        self.log_path = os.path.join(main_path, log_path)
        self.dict_path = os.path.join(main_path, dict_path)
        self.doc = fitz.open(os.path.join(main_path, pdf_path))
        with open(self.dict_path, 'r') as f:
            content = f.read()
            self.bible_dict = json.loads(content)

    def process_pdf(self):
        df = pd.DataFrame()
        if os.path.exists(self.out_file):
            return
        for page in self.doc:
            text = str(page.get_text())
            for line in text.splitlines():
                new_row = pd.DataFrame([{"lines": line}])
                df = pd.concat([df, new_row], ignore_index=True)
        df.to_csv(self.out_file)

    def get_start(self, start_idx, next_line, book_lines):
        idx = start_idx
        while "chapter" in next_line.lower() and idx < len(book_lines):
            idx += 1
            next_line = book_lines[idx]
        start = idx
        return start
    
    def get_end(self, start_idx, keyword, book_lines):
        idx = start_idx
        end = 0
        while keyword.lower() not in book_lines[idx].lower() and idx < len(book_lines):
            idx += 1
        end = idx
        return end

    @log_results
    def find_book(self, book: str, book_lines: pd.Series):
        idx = 0
        start, end = (0, 0)
        print(f"num lines in df: {len(book_lines)}")
        while idx < len(book_lines):
            line: str = book_lines.iloc[idx]
            if book.lower() in line.lower():
                if idx + 1 > len(book_lines) - 1:
                    idx += 1
                    continue
                next_line: str = book_lines[idx+1]
                start_idx = idx
                if "chapter" in next_line.lower() or (line.lower() == book.lower() and not next_line.isupper()):
                    start = self.get_start(start_idx, next_line, book_lines)
                    end = self.get_end(start, "footnotes", book_lines)
                    break
            idx += 1
        return (start, end)
    
    def remove_stops(self, line):
        doc = nlp(line)
        filtered = [word.text for word in doc if not word.is_stop]
        return filtered

    def is_header(self, line):
        words = self.remove_stops(line)
        is_header = True
        if len(words) < 2:
            return False
        for word in words:
            if not word[0].isupper() or word.isdigit():
                is_header = False
        return is_header
    
    def new_chapter(self, line, keyword=":"):
        if keyword in line:
            print(f"potential chapter: {line}")
            colon_idx = line.index(":")
            if colon_idx < len(line) - 1:
                if line[0].isdigit() and line[colon_idx+1].isdigit():
                    print(f"line proves chapter".upper())
                    return True
                else:
                    print(f"line failed to prove as chapter".upper())
            else:
                print("line failed to prove as chapter".upper())
        return False

    @log_results
    def parse_chapters(self, start: int, end: int, book_lines: pd.Series):
        idx = start
        chapters = []
        chapter = ""
        while idx < end:
            line = book_lines.loc[idx]
            if self.new_chapter(line) and len(chapter) > 0:
                chapters.append(chapter)
                chapter = line
            else:
                if self.is_header(line):
                    header = f"HEAD:: {line}"
                    chapter += header
                else:
                    chapter += f" {line}"
            
            idx += 1
        chapters.append(chapter)
        return chapters

    @log_results
    def save_chapters(self, book: str, chapters: list):
        if book not in self.bible_dict:
            return {"error": f"book({book}) not found in "}
        self.bible_dict[book] = chapters
        with open(self.dict_path, 'w') as f:
            json.dump(self.bible_dict, f, indent=2)

        return {"success": f"chapters added to {book}"}
    
def main():
    converter = ConvertBibleToDict()
    converter.process_pdf()
    df = pd.read_csv(converter.out_file)
    for book in converter.bible_dict.keys():
        start, end = converter.find_book(book, df["lines"]) 
        chapters = converter.parse_chapters(start, end, df["lines"])
        converter.save_chapters(book.strip(), chapters)

if __name__ == "__main__":
    main()