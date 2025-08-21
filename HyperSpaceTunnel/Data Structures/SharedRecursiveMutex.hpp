//
//  SharedRecursiveMutex.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

// Licensed under the MIT License <http://opensource.org/licenses/MIT>.
// SPDX-License-Identifier: MIT

#pragma once
#include <shared_mutex>
#include <thread>
#include <mutex>
#include <map>
#include <condition_variable>

namespace mtx {

//https://stackoverflow.com/questions/36619715/a-shared-recursive-mutex-in-standard-c
// Courtesy of pix64

class shared_recursive_global_mutex : public std::shared_mutex {
public:

    shared_recursive_global_mutex() = default;

    void lock() {
        std::unique_lock sync_lock(m_mtx);
        m_cond_var.wait(sync_lock, [this] { return can_exclusively_lock(); });
        if (is_exclusive_locked_on_this_thread()) {
            increment_exclusive_lock();
        } else {
            start_exclusive_lock();
        }
    }

    bool try_lock() {
        std::unique_lock sync_lock(m_mtx);
        if (can_increment_exclusive_lock()) {
            increment_exclusive_lock();
            return true;
        }
        if (can_start_exclusive_lock()) {
            start_exclusive_lock();
            return true;
        }
        return false;
    }

    void unlock() {
        {
            std::unique_lock sync_lock(m_mtx);
            decrement_exclusive_lock();
        }
        m_cond_var.notify_all();
    }

    void lock_shared() {
        std::unique_lock sync_lock(m_mtx);
        m_cond_var.wait(sync_lock, [this] { return can_lock_shared(); });
        increment_shared_lock();
    }

    bool try_lock_shared() {
        std::unique_lock sync_lock(m_mtx);
        if (can_lock_shared()) {
            increment_shared_lock();
            return true;
        }
        return false;
    }

    void unlock_shared() {
        {
            std::unique_lock sync_lock(m_mtx);
            decrement_shared_lock();
        }
        m_cond_var.notify_all();
    }

    shared_recursive_global_mutex(const shared_recursive_global_mutex&) = delete;
    shared_recursive_global_mutex& operator=(const shared_recursive_global_mutex&) = delete;

private:

    inline bool is_exclusive_locked()
    {
        return m_exclusive_count > 0;
    }

    inline bool is_shared_locked()
    {
        return m_shared_locks.size() > 0;
    }

    inline bool can_exclusively_lock()
    {
        return can_start_exclusive_lock() || can_increment_exclusive_lock();
    }

    inline bool can_start_exclusive_lock()
    {
        return !is_exclusive_locked() && (!is_shared_locked() || is_shared_locked_only_on_this_thread());
    }

    inline bool can_increment_exclusive_lock()
    {
        return is_exclusive_locked_on_this_thread();
    }

    inline bool can_lock_shared()
    {
        return !is_exclusive_locked() || is_exclusive_locked_on_this_thread();
    }

    inline bool is_shared_locked_only_on_this_thread()
    {
        return is_shared_locked_only_on_thread(std::this_thread::get_id());
    }

    inline bool is_shared_locked_only_on_thread(std::thread::id id)
    {
        return m_shared_locks.size() == 1 && m_shared_locks.find(id) != m_shared_locks.end();
    }

    inline bool is_exclusive_locked_on_this_thread()
    {
        return is_exclusive_locked_on_thread(std::this_thread::get_id());
    }

    inline bool is_exclusive_locked_on_thread(std::thread::id id)
    {
        return m_exclusive_count > 0 && m_exclusive_thread_id == id;
    }

    inline void start_exclusive_lock()
    {
        m_exclusive_thread_id = std::this_thread::get_id();
        m_exclusive_count++;
    }

    inline void increment_exclusive_lock()
    {
        m_exclusive_count++;
    }

    inline void decrement_exclusive_lock()
    {
        if (m_exclusive_count == 0)
        {
            throw std::logic_error("Not exclusively locked, cannot exclusively unlock");
        }
        if (m_exclusive_thread_id == std::this_thread::get_id())
        {
            m_exclusive_count--;
        }
        else
        {
            throw std::logic_error("Calling exclusively unlock from the wrong thread");
        }
    }

    inline void increment_shared_lock()
    {
        increment_shared_lock(std::this_thread::get_id());
    }

    inline void increment_shared_lock(std::thread::id id)
    {
        if (m_shared_locks.find(id) == m_shared_locks.end())
        {
            m_shared_locks[id] = 1;
        }
        else
        {
            m_shared_locks[id] += 1;
        }
    }

    inline void decrement_shared_lock()
    {
        decrement_shared_lock(std::this_thread::get_id());
    }

    inline void decrement_shared_lock(std::thread::id id)
    {
        if (m_shared_locks.size() == 0)
        {
            throw std::logic_error("Not shared locked, cannot shared unlock");
        }
        if (m_shared_locks.find(id) == m_shared_locks.end())
        {
            throw std::logic_error("Calling shared unlock from the wrong thread");
        }
        else
        {
            if (m_shared_locks[id] == 1)
            {
                m_shared_locks.erase(id);
            }
            else
            {
                m_shared_locks[id] -= 1;
            }
        }
    }

    std::mutex m_mtx;
    std::thread::id m_exclusive_thread_id;
    size_t m_exclusive_count = 0;
    std::map<std::thread::id, size_t> m_shared_locks;
    std::condition_variable m_cond_var;
};

}

