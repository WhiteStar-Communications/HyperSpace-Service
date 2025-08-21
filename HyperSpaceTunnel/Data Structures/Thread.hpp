//
//  Thread.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

/*
   thread.h

   Header for a Java style thread class in C++.

   ------------------------------------------

   Copyright (c) 2013 Vic Hargrave

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

#pragma once

#include <pthread.h>
#include <string>
#include <utility>
#include <memory>
#include <functional>

static void *runThread(void *arg);

class Thread {

private:
    pthread_t m_tid;
    int m_running;
    int m_detached;

public:
    std::string threadName;

    Thread(std::string name, std::function<void ()> run)
        : threadName(name)
        , fn(run)
        , m_tid(0)
        , m_running(0)
        , m_detached(0) {
    }

    Thread(std::string name)
        : threadName(name)
        , m_tid(0)
        , m_running(0)
        , m_detached(0) {
    }

    Thread()
        : m_tid(0)
        , m_running(0)
        , m_detached(0) {
    }

    ~Thread() {
        if (m_running == 1 && m_detached == 0) {
            pthread_detach(m_tid);
        }
        if (m_running == 1) {
            pthread_cancel(m_tid);
        }
    }

    int start() {
        int result = pthread_create(&m_tid, NULL, &runThread, (void *) this);
        if (result == 0) {
            m_running = 1;
        }
        return result;
    }
    
    int cancel() {
        return pthread_cancel(m_tid);
    }

    int join() {
        int result = -1;
        if (m_running == 1) {
            result = pthread_join(m_tid, NULL);
            if (result == 0) {
                m_detached = 0;
            }
        }
        return result;
    }

    int detach() {
        int result = -1;
        if (m_running == 1 && m_detached == 0) {
            result = pthread_detach(m_tid);
            if (result == 0) {
                m_detached = 1;
            }
        }
        return result;
    }

    pthread_t self() {
        return m_tid;
    }

    std::string getName() {
        return threadName;
    }

    void run() {
        try {
            fn();
            delete this;
        }
        catch (std::bad_function_call& e) {
            delete this;
        }
        catch (std::exception& e) {
            delete this;
        }
        catch (...) {
            delete this;
        }
    };

    std::function<void ()> fn = [](){
    };

    void setName(std::string threadName) {
        this->threadName = threadName;
    }
};

static void *runThread(void *arg) {
    try {
        pthread_setcanceltype(PTHREAD_CANCEL_ASYNCHRONOUS, NULL);
        pthread_setname_np(&((Thread *)arg)->threadName[0]);
        ((Thread *)arg)->run();
    } catch (std::exception& e) {
    } catch (...) {
    }

    return 0;
}

