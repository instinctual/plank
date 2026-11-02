#include "sessionlifecycle.h"
#include <cassert>
#include <iostream>
#include <thread>

int main() {
    using State = PlankSessionLifecycle::State;
    PlankSessionLifecycle state;
    assert(state.state() == State::Starting && !state.requestRecovery());
    assert(!state.recovered() && state.started() && !state.started());
    assert(state.requestRecovery() && !state.requestRecovery());
    assert(state.recoveryPending() && !state.recovering());
    assert(state.beginRecovery() && !state.beginRecovery());
    assert(!state.requestRecovery() && state.recovering());
    assert(state.recovered() && state.streaming());
    for (auto stopAt : {State::Starting, State::Streaming, State::RecoveryQueued, State::Recovering}) {
        PlankSessionLifecycle current;
        if (stopAt != State::Starting) assert(current.started());
        if (stopAt == State::RecoveryQueued || stopAt == State::Recovering) assert(current.requestRecovery());
        if (stopAt == State::Recovering) assert(current.beginRecovery());
        current.stop(); current.stop();
        assert(current.stopping() && !current.started() && !current.recovered());
        assert(!current.requestRecovery() && !current.beginRecovery());
        current.finished(); current.stop();
        assert(current.state() == State::Stopped);
    }
    // Competing network callbacks enqueue exactly one recovery. Cancellation
    // wins over a late successful worker completion without resurrecting input.
    for (int i = 0; i < 1000; ++i) {
        PlankSessionLifecycle current;
        assert(current.started());
        unsigned requests = 0;
        std::atomic_uint queued{0};
        std::thread one([&] { if (current.requestRecovery()) ++queued; });
        std::thread two([&] { if (current.requestRecovery()) ++queued; });
        one.join(); two.join(); requests = queued.load();
        assert(requests == 1 && current.beginRecovery());
        std::thread stop([&] { current.stop(); });
        current.recovered();
        stop.join();
        assert(current.stopping() && !current.recovered());
    }
    std::cout << "session lifecycle: transition matrix and 1000 concurrent recovery/cancellation races pass\n";
}
