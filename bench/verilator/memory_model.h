/*
 * fabi386: Flat 4GB Memory Model for Verilator Testbenches
 * ---------------------------------------------------------
 * Provides a simple memory model that can:
 *   - Load binary/hex images at arbitrary offsets
 *   - Read/write 8/16/32-bit values
 *   - Serve as instruction fetch and data memory backing
 *
 * Uses sparse allocation (4KB pages) to avoid allocating full 4GB.
 */

#ifndef FABI386_MEMORY_MODEL_H
#define FABI386_MEMORY_MODEL_H

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <unordered_map>
#include <vector>

class MemoryModel {
public:
    static constexpr size_t PAGE_SIZE = 4096;
    static constexpr size_t PAGE_MASK = PAGE_SIZE - 1;
    static constexpr size_t PAGE_SHIFT = 12;

    MemoryModel() = default;
    ~MemoryModel() = default;

    // Disable copy (pages are heap-allocated)
    MemoryModel(const MemoryModel&) = delete;
    MemoryModel& operator=(const MemoryModel&) = delete;

    // --- Read Operations ---
    uint8_t read8(uint32_t addr) const {
        const uint8_t* page = get_page(addr >> PAGE_SHIFT);
        if (!page) return 0xFF;  // Unmapped reads return 0xFF
        return page[addr & PAGE_MASK];
    }

    uint16_t read16(uint32_t addr) const {
        return static_cast<uint16_t>(read8(addr)) |
               (static_cast<uint16_t>(read8(addr + 1)) << 8);
    }

    uint32_t read32(uint32_t addr) const {
        return static_cast<uint32_t>(read8(addr)) |
               (static_cast<uint32_t>(read8(addr + 1)) << 8) |
               (static_cast<uint32_t>(read8(addr + 2)) << 16) |
               (static_cast<uint32_t>(read8(addr + 3)) << 24);
    }

    // 128-bit read for instruction fetch (16-byte fetch block)
    void read128(uint32_t addr, uint8_t* out) const {
        for (int i = 0; i < 16; i++) {
            out[i] = read8(addr + i);
        }
    }

    // --- Write Operations ---
    void write8(uint32_t addr, uint8_t val) {
        uint8_t* page = get_or_alloc_page(addr >> PAGE_SHIFT);
        page[addr & PAGE_MASK] = val;
    }

    void write16(uint32_t addr, uint16_t val) {
        write8(addr,     val & 0xFF);
        write8(addr + 1, (val >> 8) & 0xFF);
    }

    void write32(uint32_t addr, uint32_t val) {
        write8(addr,     val & 0xFF);
        write8(addr + 1, (val >> 8) & 0xFF);
        write8(addr + 2, (val >> 16) & 0xFF);
        write8(addr + 3, (val >> 24) & 0xFF);
    }

    // --- Image Loading ---
    bool load_binary(const std::string& filename, uint32_t base_addr) {
        std::ifstream file(filename, std::ios::binary);
        if (!file.is_open()) {
            std::cerr << "MemoryModel: Cannot open " << filename << std::endl;
            return false;
        }

        file.seekg(0, std::ios::end);
        size_t size = file.tellg();
        file.seekg(0, std::ios::beg);

        std::vector<uint8_t> data(size);
        file.read(reinterpret_cast<char*>(data.data()), size);

        for (size_t i = 0; i < size; i++) {
            write8(base_addr + static_cast<uint32_t>(i), data[i]);
        }

        std::cout << "MemoryModel: Loaded " << size << " bytes from "
                  << filename << " at 0x" << std::hex << base_addr << std::dec << std::endl;
        return true;
    }

    // Fill a region with a byte value
    void fill(uint32_t base, size_t count, uint8_t val) {
        for (size_t i = 0; i < count; i++) {
            write8(base + static_cast<uint32_t>(i), val);
        }
    }

    // --- Statistics ---
    size_t pages_allocated() const { return pages_.size(); }
    size_t bytes_allocated() const { return pages_.size() * PAGE_SIZE; }

private:
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages_;

    const uint8_t* get_page(uint32_t page_num) const {
        auto it = pages_.find(page_num);
        if (it == pages_.end()) return nullptr;
        return it->second.data();
    }

    uint8_t* get_or_alloc_page(uint32_t page_num) {
        auto& page = pages_[page_num];
        if (page.empty()) {
            page.resize(PAGE_SIZE, 0xFF);
        }
        return page.data();
    }
};

#endif // FABI386_MEMORY_MODEL_H
