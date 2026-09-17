# 独立推理工具。推理与分词复用插件的 ct2_backend.cc，此处只补一个 main。
#
# 前置：插件目录已就位且已预编 CTranslate2 静态库
#   bash librime/install-plugins.sh ... wyjrichhh/librime-ai-predict
#   ( cd librime/plugins/ai-predict && make deps )
#
# 用法：make / make check / make venv / make clean

ROOT      ?= ../..
PLUGIN    ?= $(ROOT)/librime/plugins/ai-predict
LIBRIME   ?= $(ROOT)/librime

CXX       ?= c++
CXXFLAGS  ?= -std=c++17 -O2 -Wall -Wno-deprecated-literal-operator
BUILD     ?= build
BIN       ?= infer

CT2_LIB   := $(PLUGIN)/lib/libctranslate2.a
GLOG_LIB  := $(LIBRIME)/lib/libglog.a

# ruy：CT2 若以 WITH_RUY=ON 编译，int8 内核散落在多个子归档里，而静态库不会吸收
# 依赖，必须合并后一并链接，否则链接期就报 KernelFloatNeon 之类的未定义符号。
# 没有它 CT2 只能跑 float32（见 README「两版为何会有差异」）。
RUY_BUILD := $(PLUGIN)/deps/CTranslate2/build/third_party/ruy
ifneq ($(wildcard $(RUY_BUILD)/ruy/libruy*.a),)
RUY_LIB   := $(BUILD)/libruy.a
endif

# glog 0.7+ 要求消费方定义这些宏（同插件 CMakeLists.txt）。
# 括号会让 /bin/sh 误判语法，故加引号。
GLOG_DEFS := '-DGLOG_DEPRECATED=__attribute__((deprecated))' -DGLOG_EXPORT= -DGLOG_NO_EXPORT=
INCLUDES  := -I$(PLUGIN)/src -I$(PLUGIN)/include -I$(LIBRIME)/include

LDLIBS    := $(CT2_LIB) $(RUY_LIB) $(GLOG_LIB) -framework Accelerate -ldl -lpthread

PYTHON    ?= python3
VENV      ?= .venv

OBJS := $(BUILD)/main.o $(BUILD)/ct2_backend.o

.PHONY: all check parity repl sweep venv clean

all: $(BIN)

ifeq ($(wildcard $(PLUGIN)/src/ct2_backend.cc),)
$(error 找不到 $(PLUGIN)/src/ct2_backend.cc — 先运行 bash librime/install-plugins.sh hchunhui/librime-lua lotem/librime-octagram rime/librime-predict wyjrichhh/librime-ai-predict)
endif

ifeq ($(wildcard $(CT2_LIB)),)
$(error 找不到 $(CT2_LIB) — 先运行 ( cd $(PLUGIN) && make deps ))
endif

$(BIN): $(OBJS) $(RUY_LIB)
	$(CXX) $(CXXFLAGS) $(OBJS) $(LDLIBS) -o $@

$(RUY_LIB): | $(BUILD)
	libtool -static -o $@ \
	  $(RUY_BUILD)/ruy/libruy*.a \
	  $(RUY_BUILD)/ruy/profiler/libruy_profiler_instrumentation.a \
	  $(RUY_BUILD)/third_party/cpuinfo/libcpuinfo.a \
	  $(RUY_BUILD)/third_party/cpuinfo/deps/clog/libclog.a

$(BUILD)/main.o: main.cc | $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLOG_DEFS) $(INCLUDES) -c $< -o $@

$(BUILD)/ct2_backend.o: $(PLUGIN)/src/ct2_backend.cc | $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLOG_DEFS) $(INCLUDES) -c $< -o $@

$(BUILD):
	mkdir -p $@

# 端到端自检：模型能加载，且 README 里的示例输入给出预期输出
check: $(BIN)
	./$(BIN) 今天天气 zenmeyang

# 交叉验证：两版逐字段比对
parity: $(BIN) $(VENV)/bin/python
	./parity.py

# 交互式验证台（自动备好两版）
repl: $(BIN) $(VENV)/bin/python
	./session.py

# 在标注测试集上扫参数
sweep: $(VENV)/bin/python
	./sweep.py

venv: $(VENV)/bin/python

$(VENV)/bin/python: requirements.txt
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q -r requirements.txt

clean:
	rm -rf $(BUILD) $(BIN)
