//
//  Semaphore.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#pragma once

#include <vector>
#include <list>
#include <mutex>
#include <shared_mutex>
#include <optional>
#include <atomic>
#include <limits>
#include <string>
#include <iostream>

namespace hs {
    class Semaphore {
    private:
        pthread_mutex_t lock = pthread_mutex_t();
        pthread_cond_t cv = pthread_cond_t();
    public:
        long count = 0;

        Semaphore() {
            pthread_mutex_init(&lock, nullptr);
            pthread_cond_init(&cv, nullptr);
        }

        explicit Semaphore(const long val) {
            this->count = val;
            pthread_mutex_init(&lock, nullptr);
            pthread_cond_init(&cv, nullptr);
        }

        // Acquire & Wait
        void wait() {
            pthread_mutex_lock(&lock);

            while (count <= 0) {
                pthread_cond_wait(&cv, &lock);
            }

            count--;

            pthread_mutex_unlock(&lock);
        }

        void waitNanos(long duration) {
            pthread_mutex_lock(&lock);

            struct timespec timeToWait;

            // no great monotonic clock support...
            //clock_gettime(CLOCK_MONOTONIC, &timeToWait);

            clock_gettime(CLOCK_REALTIME, &timeToWait);

            // tv_nsec has to be less than 1bn (1 second's worth)
            // so determine what we add to sec
            timeToWait.tv_sec += duration / (long) 1'000'000'000;

            pthread_cond_timedwait(&cv, &lock, &timeToWait);

            pthread_mutex_unlock(&lock);
        }

        // Acquire & Signal
        void signal() {
            pthread_mutex_lock(&lock);
            count += 1;

            if (count >= 1) {
                pthread_cond_signal(&cv);
            }
            pthread_mutex_unlock(&lock);
        }

        void reset() {
            pthread_mutex_lock(&lock);

            if (count >= 1) {
                pthread_cond_signal(&cv);
            }

            pthread_mutex_unlock(&lock);
        }
    };
}


