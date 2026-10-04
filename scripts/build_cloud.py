"""Copy the calendar page into the Worker's static assets."""
from pathlib import Path
import shutil


def main():
    root = Path(__file__).resolve().parent.parent
    (root/'cloud/public').mkdir(exist_ok=True)
    shutil.copyfile(root/'index.html', root/'cloud/public/index.html')


if __name__ == '__main__':
    main()
