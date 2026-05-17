PRODUCT = quality-gate
PREFIX ?= /usr/local/custom
INSTALL_DIR = $(PREFIX)/bin
BUILD_DIR_RELEASE = .build/release
BUILD_DIR_DEBUG = .build/debug

.PHONY: build install uninstall clean sign-debug

build:
	swift build -c release --product $(PRODUCT)
	codesign -s - --force --options runtime $(BUILD_DIR_RELEASE)/$(PRODUCT)

sign-debug:
	codesign -s - --force --options runtime $(BUILD_DIR_DEBUG)/$(PRODUCT)

install: build
	sudo install -d $(INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR_RELEASE)/$(PRODUCT) $(INSTALL_DIR)/$(PRODUCT)
	sudo xattr -cr $(INSTALL_DIR)/$(PRODUCT)

uninstall:
	sudo rm -f $(INSTALL_DIR)/$(PRODUCT)

clean:
	swift package clean
