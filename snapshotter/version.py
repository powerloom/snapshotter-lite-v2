import toml

# Read version from pyproject.toml
with open("pyproject.toml", "r") as f:
    pyproject = toml.load(f)
    __version__ = pyproject["tool"]["poetry"]["version"]

if __name__ == "__main__":
    print(f"Snapshotter Lite v2 version: v{__version__}")
