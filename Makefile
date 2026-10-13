# 品牌值全部来自 Brand.xcconfig（单一事实来源），别在这里写死产物名
BRAND_SH = bash scripts/brand.sh
PRODUCT_NAME = $(shell $(BRAND_SH) BRAND_PRODUCT_NAME)
APP_NAME = $(shell $(BRAND_SH) APP_NAME)

.PHONY: all install deps release debug

all: release
install: install-release

RIME_BIN_DIR = librime/dist/bin
RIME_LIB_DIR = librime/dist/lib
DERIVED_DATA_PATH = build

RIME_LIBRARY_FILE_NAME = librime.1.dylib
RIME_LIBRARY = lib/$(RIME_LIBRARY_FILE_NAME)

RIME_DEPS = librime/lib/libmarisa.a \
	librime/lib/libleveldb.a \
	librime/lib/libopencc.a \
	librime/lib/libyaml-cpp.a
PLUM_DATA = bin/rime-install \
	data/plum/default.yaml \
	data/plum/symbols.yaml \
	data/plum/essay.txt
OPENCC_DATA = data/opencc/TSCharacters.ocd2 \
	data/opencc/TSPhrases.ocd2 \
	data/opencc/t2s.json
SPARKLE_FRAMEWORK = Frameworks/Sparkle.framework
DEPS_CHECK = $(RIME_LIBRARY) $(PLUM_DATA) $(OPENCC_DATA) $(SPARKLE_FRAMEWORK)

OPENCC_DATA_OUTPUT = librime/share/opencc/*.*
PLUM_DATA_OUTPUT = plum/output/*.*
PLUM_OPENCC_OUTPUT = plum/output/opencc/*.*
RIME_PACKAGE_INSTALLER = plum/rime-install

INSTALL_NAME_TOOL = $(shell xcrun -find install_name_tool)
INSTALL_NAME_TOOL_ARGS = -add_rpath @loader_path/../Frameworks

.PHONY: librime copy-rime-binaries

$(RIME_LIBRARY):
	$(MAKE) librime

$(RIME_DEPS):
	$(MAKE) -C librime deps

librime: $(RIME_DEPS)
	# 两个目标必须**串行**：librime 的 Makefile 自己开 -j，而 release 与 install 各自
	# 起一个 `cmake --build build`，并行跑会同时编/链同一批目标 —— 真机撞到过
	# "ld: open() failed, errno=17 (File exists) for 'rime_test'"（同一个目标链两次）。
	$(MAKE) -C librime release
	$(MAKE) -C librime install
	$(MAKE) copy-rime-binaries

copy-rime-binaries:
	cp -L $(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME) lib/
	cp -pR $(RIME_LIB_DIR)/rime-plugins lib/
	cp $(RIME_BIN_DIR)/rime_deployer bin/
	cp $(RIME_BIN_DIR)/rime_dict_manager bin/
	$(INSTALL_NAME_TOOL) $(INSTALL_NAME_TOOL_ARGS) bin/rime_deployer
	$(INSTALL_NAME_TOOL) $(INSTALL_NAME_TOOL_ARGS) bin/rime_dict_manager

.PHONY: data plum-data opencc-data copy-plum-data copy-opencc-data

data: plum-data opencc-data

$(PLUM_DATA):
	$(MAKE) plum-data

$(OPENCC_DATA):
	$(MAKE) opencc-data

plum-data:
	$(MAKE) -C plum
ifdef PLUM_TAG
	rime_dir=plum/output bash plum/rime-install $(PLUM_TAG)
endif
	$(MAKE) copy-plum-data

opencc-data:
	$(MAKE) -C librime deps/opencc
	$(MAKE) copy-opencc-data

copy-plum-data:
	mkdir -p data/plum
	cp $(PLUM_DATA_OUTPUT) data/plum/
	cp $(RIME_PACKAGE_INSTALLER) bin/

copy-opencc-data:
	mkdir -p data/opencc
	cp $(OPENCC_DATA_OUTPUT) data/opencc/
	cp $(PLUM_OPENCC_OUTPUT) data/opencc/ > /dev/null 2>&1 || true

deps: librime data

ifdef ARCHS
BUILD_SETTINGS += ARCHS="$(ARCHS)"
BUILD_SETTINGS += ONLY_ACTIVE_ARCH=NO
_=$() $()
export CMAKE_OSX_ARCHITECTURES = $(subst $(_),;,$(ARCHS))
endif

ifdef MACOSX_DEPLOYMENT_TARGET
BUILD_SETTINGS += MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"
endif

# 构建号由 package/build-pkg 按 git 提交数注入（落到 CFBundleVersion）。走专用变量而
# 不是从命令行覆盖 BUILD_SETTINGS —— 后者是 += 累积的，命令行传参会整个顶掉，连带丢
# 掉 ARCHS / ONLY_ACTIVE_ARCH。不传时沿用工程里的占位值 0，即开发构建。
ifdef BUILD_NUMBER
BUILD_SETTINGS += CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)"
endif

BUILD_SETTINGS += COMPILER_INDEX_STORE_ENABLE=YES

release: $(DEPS_CHECK)
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Bangke.xcodeproj -configuration Release -scheme Bangke -derivedDataPath $(DERIVED_DATA_PATH) $(BUILD_SETTINGS) build

debug: $(DEPS_CHECK)
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Bangke.xcodeproj -configuration Debug -scheme Bangke -derivedDataPath $(DERIVED_DATA_PATH)  $(BUILD_SETTINGS) build

.PHONY: sparkle copy-sparkle-framework

$(SPARKLE_FRAMEWORK):
	git submodule update --init --recursive Sparkle
	$(MAKE) sparkle

sparkle:
	xcodebuild -project Sparkle/Sparkle.xcodeproj -configuration Release $(BUILD_SETTINGS) build
	$(MAKE) copy-sparkle-framework

package/generate_keys:
	xcodebuild -project Sparkle/Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath Sparkle/build $(BUILD_SETTINGS) build
	cp Sparkle/build/Build/Products/Release/generate_keys package/

package/sign_update:
	xcodebuild -project Sparkle/Sparkle.xcodeproj -scheme sign_update -configuration Release -derivedDataPath Sparkle/build $(BUILD_SETTINGS) build
	cp Sparkle/build/Build/Products/Release/sign_update package/

copy-sparkle-framework:
	mkdir -p Frameworks
	cp -RP Sparkle/build/Release/Sparkle.framework Frameworks/

clean-sparkle:
	rm -rf Frameworks/* > /dev/null 2>&1 || true
	rm -rf Sparkle/build > /dev/null 2>&1 || true

# 出分发用 pkg 只有这一条路（编译 + 注入模型/配置 + 签名 + 公证 + 验证）。
# `make package` 只是它的别名，避免两套打包实现漂移。
.PHONY: package

package:
	@DEV_ID="$(DEV_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ARCHS="$(ARCHS)" \
	 MODEL_SRC="$(MODEL_SRC)" SKIP_BUILD="$(SKIP_BUILD)" SKIP_NOTARIZE="$(SKIP_NOTARIZE)" \
	 bash package/build-pkg

DSTROOT = /Library/Input Methods
APP_ROOT = $(DSTROOT)/$(APP_NAME)

.PHONY: permission-check install-debug install-release

permission-check:
	[ -w "$(DSTROOT)" ] && [ -w "$(APP_ROOT)" ] || sudo chown -R ${USER} "$(DSTROOT)"

install-debug: debug permission-check
	rm -rf "$(APP_ROOT)"
	cp -R $(DERIVED_DATA_PATH)/Build/Products/Debug/$(APP_NAME) "$(DSTROOT)"
	DSTROOT="$(DSTROOT)" RIME_NO_PREBUILD=1 bash scripts/dev-install

install-release: release permission-check
	rm -rf "$(APP_ROOT)"
	cp -R $(DERIVED_DATA_PATH)/Build/Products/Release/$(APP_NAME) "$(DSTROOT)"
	DSTROOT="$(DSTROOT)" bash scripts/dev-install

.PHONY: clean clean-deps

clean:
	rm -rf build > /dev/null 2>&1 || true
	rm build.log > /dev/null 2>&1 || true
	rm bin/* > /dev/null 2>&1 || true
	rm lib/* > /dev/null 2>&1 || true
	rm lib/rime-plugins/* > /dev/null 2>&1 || true
	rm data/plum/* > /dev/null 2>&1 || true
	rm data/opencc/* > /dev/null 2>&1 || true

clean-package:
	rm -rf package/*.pkg > /dev/null 2>&1 || true
	rm -rf package/sign_update > /dev/null 2>&1 || true

clean-deps:
	$(MAKE) -C plum clean
	$(MAKE) -C librime clean
	rm -rf librime/dist > /dev/null 2>&1 || true
	$(MAKE) clean-sparkle
