// A mid-sized C++ translation unit for the clangd memory spike: a tiny JSON
// parser and an expression evaluator over the standard library. What makes it
// "medium" for clangd is mostly the preamble (libc++ headers); the body adds
// templates, lambdas and variants for the AST.

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <numeric>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace mini {

struct Json;
using Array = std::vector<Json>;
using Object = std::map<std::string, Json, std::less<>>;

struct Json {
  std::variant<std::nullptr_t, bool, double, std::string, Array, Object> value;

  bool isNull() const { return std::holds_alternative<std::nullptr_t>(value); }
  const Object *object() const { return std::get_if<Object>(&value); }
  const Array *array() const { return std::get_if<Array>(&value); }
  std::optional<double> number() const {
    if (auto *d = std::get_if<double>(&value)) return *d;
    return std::nullopt;
  }
};

class Parser {
public:
  explicit Parser(std::string_view text) : text_(text) {}

  std::optional<Json> parse() {
    auto v = parseValue();
    skipSpace();
    if (!v || pos_ != text_.size()) return std::nullopt;
    return v;
  }

private:
  void skipSpace() {
    while (pos_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[pos_]))) ++pos_;
  }
  bool consume(char c) {
    skipSpace();
    if (pos_ < text_.size() && text_[pos_] == c) { ++pos_; return true; }
    return false;
  }
  bool consumeWord(std::string_view word) {
    if (text_.substr(pos_, word.size()) == word) { pos_ += word.size(); return true; }
    return false;
  }

  std::optional<Json> parseValue() {
    skipSpace();
    if (pos_ >= text_.size()) return std::nullopt;
    switch (text_[pos_]) {
    case '{': return parseObject();
    case '[': return parseArray();
    case '"': {
      auto s = parseString();
      if (!s) return std::nullopt;
      return Json{std::move(*s)};
    }
    case 't': if (consumeWord("true")) return Json{true}; return std::nullopt;
    case 'f': if (consumeWord("false")) return Json{false}; return std::nullopt;
    case 'n': if (consumeWord("null")) return Json{nullptr}; return std::nullopt;
    default: return parseNumber();
    }
  }

  std::optional<std::string> parseString() {
    if (!consume('"')) return std::nullopt;
    std::string out;
    while (pos_ < text_.size() && text_[pos_] != '"') {
      char c = text_[pos_++];
      if (c == '\\' && pos_ < text_.size()) {
        char e = text_[pos_++];
        switch (e) {
        case 'n': out += '\n'; break;
        case 't': out += '\t'; break;
        default: out += e; break;
        }
      } else {
        out += c;
      }
    }
    if (pos_ >= text_.size()) return std::nullopt;
    ++pos_;
    return out;
  }

  std::optional<Json> parseNumber() {
    size_t start = pos_;
    while (pos_ < text_.size() && (std::isdigit(static_cast<unsigned char>(text_[pos_])) ||
                                   text_[pos_] == '-' || text_[pos_] == '.' || text_[pos_] == 'e'))
      ++pos_;
    if (start == pos_) return std::nullopt;
    return Json{std::stod(std::string(text_.substr(start, pos_ - start)))};
  }

  std::optional<Json> parseArray() {
    consume('[');
    Array items;
    if (consume(']')) return Json{std::move(items)};
    do {
      auto v = parseValue();
      if (!v) return std::nullopt;
      items.push_back(std::move(*v));
    } while (consume(','));
    if (!consume(']')) return std::nullopt;
    return Json{std::move(items)};
  }

  std::optional<Json> parseObject() {
    consume('{');
    Object members;
    if (consume('}')) return Json{std::move(members)};
    do {
      skipSpace();
      auto key = parseString();
      if (!key || !consume(':')) return std::nullopt;
      auto v = parseValue();
      if (!v) return std::nullopt;
      members.emplace(std::move(*key), std::move(*v));
    } while (consume(','));
    if (!consume('}')) return std::nullopt;
    return Json{std::move(members)};
  }

  std::string_view text_;
  size_t pos_ = 0;
};

// A small evaluator: {"op": "+", "args": [...]} trees over numbers.
class Evaluator {
public:
  Evaluator() {
    ops_["+"] = [](const std::vector<double> &a) { return std::accumulate(a.begin(), a.end(), 0.0); };
    ops_["*"] = [](const std::vector<double> &a) {
      return std::accumulate(a.begin(), a.end(), 1.0, std::multiplies<>());
    };
    ops_["max"] = [](const std::vector<double> &a) {
      return a.empty() ? 0.0 : *std::max_element(a.begin(), a.end());
    };
    ops_["min"] = [](const std::vector<double> &a) {
      return a.empty() ? 0.0 : *std::min_element(a.begin(), a.end());
    };
  }

  std::optional<double> eval(const Json &node) const {
    if (auto n = node.number()) return n;
    const Object *obj = node.object();
    if (!obj) return std::nullopt;
    auto op = obj->find("op");
    auto args = obj->find("args");
    if (op == obj->end() || args == obj->end()) return std::nullopt;
    auto *name = std::get_if<std::string>(&op->second.value);
    auto *list = args->second.array();
    if (!name || !list) return std::nullopt;
    auto fn = ops_.find(*name);
    if (fn == ops_.end()) return std::nullopt;
    std::vector<double> values;
    values.reserve(list->size());
    for (const Json &arg : *list) {
      auto v = eval(arg);
      if (!v) return std::nullopt;
      values.push_back(*v);
    }
    return fn->second(values);
  }

private:
  std::unordered_map<std::string, std::function<double(const std::vector<double> &)>> ops_;
};

template <typename Visitor>
void walk(const Json &node, Visitor &&visit, int depth = 0) {
  visit(node, depth);
  if (auto *a = node.array())
    for (const Json &child : *a) walk(child, visit, depth + 1);
  if (auto *o = node.object())
    for (const auto &[key, child] : *o) walk(child, visit, depth + 1);
}

} // namespace mini

int main() {
  const char *program = R"({"op": "+", "args": [1, 2, {"op": "*", "args": [3, 4, 5]},
                            {"op": "max", "args": [7, 9.5, -1]}]})";
  auto json = mini::Parser(program).parse();
  if (!json) {
    std::puts("parse error");
    return 1;
  }
  int nodes = 0, deepest = 0;
  mini::walk(*json, [&](const mini::Json &, int depth) {
    ++nodes;
    deepest = std::max(deepest, depth);
  });
  auto result = mini::Evaluator().eval(*json);
  std::ostringstream out;
  out << "nodes=" << nodes << " depth=" << deepest << " result=" << result.value_or(-1);
  std::puts(out.str().c_str());
  return 0;
}
