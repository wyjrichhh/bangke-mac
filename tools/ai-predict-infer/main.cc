// 独立推理入口：加载模型，跑一次「上文 + 拼音 → 模型输出」。
//
// 刻意不做任何业务前置——不套插件的 prompt 门禁、不剥标点、不判候选资格。
// 这里只回答两件事：模型能接收什么输入、对这些输入推理出什么。业务侧怎么用
// 这些输出（拦哪些、剥哪些、显不显示）是插件的事，不在此处模拟。
//
// 推理直接复用插件的 CT2Backend（ct2_backend.cc），与输入法内是同一份
// tokenize / 解码 / detokenize 代码，所以模型行为可直接外推到线上。

#include <glog/logging.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "ct2_backend.h"

namespace {

using rime::predict::CT2Backend;
using rime::predict::InferenceBackendConfig;

constexpr int kDefaultMaxTokens = 64;

std::string DefaultModelPath() {
  const char* home = std::getenv("HOME");
  return std::string(home ? home : ".") +
         "/Library/Rime/predict_models/zh-base-ct2-int8";
}

struct Options {
  std::string model = DefaultModelPath();
  std::string device = "cpu";
  int max_tokens = kDefaultMaxTokens;
  bool json = false;
  bool verbose = false;
};

void PrintUsage(const char* argv0) {
  std::cout
      << "用法:\n"
      << "  " << argv0 << "                    交互模式\n"
      << "  " << argv0 << " <拼音>              冷启动（无上文）\n"
      << "  " << argv0 << " <上文> <拼音>        带上文\n\n"
      << "选项:\n"
      << "  --model PATH      模型目录 (默认 ~/Library/Rime/predict_models/"
         "zh-base-ct2-int8)\n"
      << "  --device DEV      cpu | cuda (默认 cpu)\n"
      << "  --max-tokens N    最大生成长度 (默认 " << kDefaultMaxTokens << ")\n"
      << "  --json            以 JSON 行输出，便于脚本消费\n"
      << "  --verbose         打开插件的 INFO 日志（模型加载、耗时明细）\n"
      << "  -h, --help        显示本帮助\n\n"
      << "交互模式输入格式: <上文> <拼音>，只填拼音则视为冷启动；"
         "exit / quit 退出。\n";
}

// 返回 false 表示参数有误（已打印原因）。
bool ParseArgs(int argc, char** argv, Options* opt,
               std::vector<std::string>* positional) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    auto value_of = [&](std::string* out) {
      if (i + 1 >= argc) {
        std::cerr << "缺少 " << arg << " 的值\n";
        return false;
      }
      *out = argv[++i];
      return true;
    };
    if (arg == "-h" || arg == "--help") {
      PrintUsage(argv[0]);
      std::exit(0);
    } else if (arg == "--json") {
      opt->json = true;
    } else if (arg == "--verbose") {
      opt->verbose = true;
    } else if (arg == "--model") {
      if (!value_of(&opt->model))
        return false;
    } else if (arg == "--device") {
      if (!value_of(&opt->device))
        return false;
    } else if (arg == "--max-tokens") {
      std::string v;
      if (!value_of(&v))
        return false;
      opt->max_tokens = std::atoi(v.c_str());
      if (opt->max_tokens <= 0) {
        std::cerr << "--max-tokens 必须是正整数\n";
        return false;
      }
    } else if (!arg.empty() && arg[0] == '-') {
      std::cerr << "未知选项: " << arg << "\n";
      return false;
    } else {
      positional->push_back(arg);
    }
  }
  if (positional->size() > 2) {
    std::cerr << "最多接受两个位置参数（上文、拼音）\n";
    return false;
  }
  return true;
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  for (char c : s) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out += c;
    }
  }
  return out;
}

void RunOne(CT2Backend& backend, const Options& opt, const std::string& window,
            const std::string& prompt) {
  // 与 context_builder.cc 构造的 ct2_input 一致：这是模型约定的输入格式，
  // 不是业务过滤。
  std::string input = window + "<pinyin_start>" + prompt + "</pinyin_start>";

  auto start = std::chrono::steady_clock::now();
  auto output = backend.Predict(input, opt.max_tokens);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start)
                .count();

  std::string text = output ? *output : "";
  if (opt.json) {
    std::cout << "{\"window\":\"" << JsonEscape(window) << "\",\"prompt\":\""
              << JsonEscape(prompt) << "\",\"input\":\"" << JsonEscape(input)
              << "\",\"output\":\"" << JsonEscape(text) << "\",\"ms\":" << ms
              << "}" << std::endl;
    return;
  }

  std::cout << "window  " << window << "\n"
            << "prompt  " << prompt << "\n"
            << "output  " << (output ? text : "(无输出)") << "\n"
            << "time    " << ms << " ms\n";
}

// --json 下退化为「一行输入换一行 JSON」的协议，不打印提示符与横幅，
// 以便被 session.py 之类的驱动脚本当作长驻子进程使用。
void Repl(CT2Backend& backend, const Options& opt) {
  if (!opt.json)
    std::cout << "输入 <上文> <拼音>（只填拼音为冷启动），exit/quit 退出。\n";
  std::string line;
  while (true) {
    if (!opt.json)
      std::cout << "> " << std::flush;
    if (!std::getline(std::cin, line))
      break;
    if (!line.empty() && line.back() == '\r')
      line.pop_back();
    if (line == "exit" || line == "quit")
      break;
    if (line.empty())
      continue;

    auto sep = line.find(' ');
    std::string window = sep == std::string::npos ? "" : line.substr(0, sep);
    std::string prompt = sep == std::string::npos ? line : line.substr(sep + 1);
    if (prompt.empty()) {
      if (!opt.json)
        std::cout << "需要拼音输入\n";
      continue;
    }
    if (!opt.json)
      std::cout << "\n";
    RunOne(backend, opt, window, prompt);
    if (!opt.json)
      std::cout << "\n";
  }
}

}  // namespace

int main(int argc, char** argv) {
  Options opt;
  std::vector<std::string> positional;
  if (!ParseArgs(argc, argv, &opt, &positional))
    return 2;

  // 只放行 ERROR，保证 stdout 干净；插件细节留给 --verbose。
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = true;
  FLAGS_minloglevel = opt.verbose ? google::GLOG_INFO : google::GLOG_ERROR;

  InferenceBackendConfig config;
  config.model_path = opt.model;
  config.device = opt.device;

  CT2Backend backend;
  if (!backend.Initialize(config)) {
    std::cerr << "模型加载失败: " << opt.model << "\n";
    return 1;
  }

  if (positional.empty()) {
    Repl(backend, opt);
  } else if (positional.size() == 1) {
    RunOne(backend, opt, "", positional[0]);
  } else {
    RunOne(backend, opt, positional[0], positional[1]);
  }

  backend.Shutdown();
  return 0;
}
