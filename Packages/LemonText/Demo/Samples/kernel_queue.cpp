// kernel_queue.cpp — schedules GPU dispatches and tracks their completion.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <deque>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace lemonseed {

enum class DispatchState : std::uint8_t { Pending, Running, Done, Faulted };

struct Dispatch {
    std::uint64_t id = 0;
    std::uint32_t grid[3] = {1, 1, 1};
    std::uint32_t block[3] = {64, 1, 1};
    DispatchState state = DispatchState::Pending;
    std::chrono::nanoseconds elapsed{0};
};

template <typename Clock = std::chrono::steady_clock>
class KernelQueue {
public:
    explicit KernelQueue(std::size_t depth) : depth_(depth) {}

    [[nodiscard]] std::optional<std::uint64_t> submit(std::span<const std::uint32_t, 3> grid) {
        if (inFlight_.size() >= depth_) {
            return std::nullopt;  // back-pressure: the ring is full
        }
        Dispatch dispatch{.id = nextID_++};
        std::copy(grid.begin(), grid.end(), dispatch.grid);
        inFlight_.push_back(dispatch);
        return dispatch.id;
    }

    void complete(std::uint64_t id, std::chrono::nanoseconds elapsed) noexcept {
        auto match = std::ranges::find(inFlight_, id, &Dispatch::id);
        if (match == inFlight_.end()) {
            return;
        }
        match->state = DispatchState::Done;
        match->elapsed = elapsed;
        while (!inFlight_.empty() && inFlight_.front().state == DispatchState::Done) {
            finished_.push_back(inFlight_.front());
            inFlight_.pop_front();
        }
    }

    [[nodiscard]] double throughput(std::string_view label) const {
        const auto total = std::ranges::fold_left(finished_, std::chrono::nanoseconds{0},
            [](auto sum, const Dispatch& d) { return sum + d.elapsed; });
        return total.count() == 0 ? 0.0 : static_cast<double>(finished_.size()) / total.count() * 1e9;
    }

private:
    std::size_t depth_;
    std::uint64_t nextID_ = 1;
    std::deque<Dispatch> inFlight_;
    std::vector<Dispatch> finished_;
};

}  // namespace lemonseed
