// Read-only, bounded inference protocol. stdout carries the result, never diagnostics or prompts.
// Built against the exact llama.cpp version recorded in EmbeddingRuntime/provenance.json.
#include "llama.h"
#include <algorithm>
#include <chrono>
#include <clocale>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

static void set_batch(llama_batch_ext * batch, const llama_token * tokens, int count, int position) {
    llama_batch_ext_clear(batch);
    for (int i = 0; i < count; ++i) {
        const int index = llama_batch_ext_add_token(batch, 0, tokens[i]);
        const llama_pos pos = position + i;
        llama_batch_ext_set_pos(batch, index, &pos);
    }
    llama_batch_ext_set_output_logits(batch, count - 1, true);
}

int main(int argc, char ** argv) {
    if (argc != 2) { return 2; }
    const pid_t owner = getppid();
    std::thread([owner] {
        while (getppid() == owner) { std::this_thread::sleep_for(std::chrono::milliseconds(200)); }
        _exit(1);
    }).detach();
    std::setlocale(LC_NUMERIC, "C");
    llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    std::string prompt;
    char input[4096];
    while (size_t count = std::fread(input, 1, sizeof(input), stdin)) {
        if (prompt.size() + count > 32768) { return 2; }
        prompt.append(input, count);
    }
    if (prompt.empty() || std::ferror(stdin)) { return 2; }
    llama_backend_init();
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 99;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
        llama_model_load_from_file(argv[1], model_params), llama_model_free);
    if (!model) { return 3; }
    const auto * vocab = llama_model_get_vocab(model.get());
    // The trusted ChatML prompt already includes LFM's BOS token.
    const int count = -llama_tokenize(vocab, prompt.data(), prompt.size(), nullptr, 0, false, true);
    constexpr int max_output = 48;
    if (count <= 0 || count + max_output > 4096) { return 4; }
    std::vector<llama_token> tokens(count);
    if (llama_tokenize(vocab, prompt.data(), prompt.size(), tokens.data(), count, false, true) != count) { return 4; }
    auto context_params = llama_context_default_params();
    context_params.n_ctx = count + max_output;
    context_params.n_batch = count;
    context_params.n_ubatch = count;
    context_params.n_threads = 4;
    context_params.n_threads_batch = 4;
    context_params.no_perf = true;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(
        llama_init_from_model(model.get(), context_params), llama_free);
    if (!context) { return 5; }
    auto sampler_params = llama_sampler_chain_default_params();
    sampler_params.no_perf = true;
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_chain_init(sampler_params), llama_sampler_free);
    // A single closed domain keeps this a classifier. Swift independently validates the envelope.
    static const char * grammar = R"grammar(
root ::= "{" ws "\"domain\"" ws ":" ws domain ws "}" ws
domain ::= "\"" ("conversation" | "files" | "coding" | "execution" | "knowledge" | "memory" | "mail" | "web" | "browser" | "reminders" | "notes" | "apps" | "scheduling" | "agents" | "database" | "skills" | "management" | "unknown") "\""
ws ::= [ \t\n\r]*
)grammar";
    auto * constraint = llama_sampler_init_grammar(vocab, grammar, "root");
    if (!sampler || !constraint) { return 6; }
    llama_sampler_chain_add(sampler.get(), constraint);
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
    std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch(
        llama_batch_ext_init(context.get()), llama_batch_ext_free);
    if (!batch) { return 5; }
    set_batch(batch.get(), tokens.data(), count, 0);
    int position = count;
    std::string result;
    bool complete = false;
    for (int step = 0; step < max_output; ++step) {
        if (llama_process(context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get()) != 0) { return 7; }
        const llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) { break; }
        char piece[1024];
        const int size = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (size < 0 || result.size() + size > 4096) { return 8; }
        result.append(piece, size);
        if (result.find('}') != std::string::npos) { complete = true; break; }
        set_batch(batch.get(), &token, 1, position++);
    }
    if (!complete) { return 9; }
    std::fwrite(result.data(), 1, result.size(), stdout);
    return std::ferror(stdout) ? 10 : 0;
}
