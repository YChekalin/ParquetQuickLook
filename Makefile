TARGET := ParquetQuickLook
BUNDLE := $(TARGET).qlgenerator
CONTENTS := $(BUNDLE)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources

SRC := main.c GeneratePreviewForURL.c
BIN := $(MACOS)/$(TARGET)

CFLAGS := -O2 -Wall -Wextra -std=c11
LDFLAGS := -framework CoreFoundation -framework QuickLook -framework CoreServices

.PHONY: all clean install uninstall

all: $(BUNDLE)

$(BUNDLE): $(SRC) Info.plist parquet_quicklook.py
	mkdir -p $(MACOS) $(RESOURCES)
	clang $(CFLAGS) -bundle $(SRC) -o $(BIN) $(LDFLAGS)
	cp Info.plist $(CONTENTS)/Info.plist
	cp parquet_quicklook.py $(RESOURCES)/parquet_quicklook.py
	chmod +x $(RESOURCES)/parquet_quicklook.py

install: all
	mkdir -p "$(HOME)/Library/QuickLook"
	ditto "$(BUNDLE)" "$(HOME)/Library/QuickLook/$(BUNDLE)"
	qlmanage -r
	qlmanage -r cache

uninstall:
	rm -rf "$(HOME)/Library/QuickLook/$(BUNDLE)"
	qlmanage -r
	qlmanage -r cache

clean:
	rm -rf "$(BUNDLE)"
