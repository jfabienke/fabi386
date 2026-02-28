# fabi386 CI/Verification Docker Image
# Contains: Verilator, Yosys, SymbiYosys, GCC, sv2v
#
# Build: docker build -t fabi386-ci docker/
# Run:   docker run --rm -v $(pwd):/work -w /work fabi386-ci make -C bench/verilator test

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Base dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    autoconf \
    flex \
    bison \
    libfl-dev \
    pkg-config \
    zlib1g-dev \
    libreadline-dev \
    tcl-dev \
    libffi-dev \
    gperf \
    && rm -rf /var/lib/apt/lists/*

# Verilator (from source for latest version)
ARG VERILATOR_VERSION=v5.024
RUN cd /tmp && \
    git clone --depth 1 --branch ${VERILATOR_VERSION} https://github.com/verilator/verilator.git && \
    cd verilator && \
    autoconf && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/verilator

# Yosys (from source)
ARG YOSYS_VERSION=yosys-0.38
RUN cd /tmp && \
    git clone --depth 1 --branch ${YOSYS_VERSION} https://github.com/YosysHQ/yosys.git && \
    cd yosys && \
    make -j$(nproc) PREFIX=/usr/local && \
    make install PREFIX=/usr/local && \
    rm -rf /tmp/yosys

# SymbiYosys (formal verification frontend)
RUN cd /tmp && \
    git clone --depth 1 https://github.com/YosysHQ/sby.git && \
    cd sby && \
    make install PREFIX=/usr/local && \
    rm -rf /tmp/sby

# SMT solver for formal verification
RUN pip3 install z3-solver

# sv2v (SystemVerilog to Verilog converter)
RUN cd /tmp && \
    curl -L -o sv2v.tar.gz \
    https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.tar.gz && \
    tar xzf sv2v.tar.gz && \
    cp sv2v-Linux/sv2v /usr/local/bin/ && \
    rm -rf /tmp/sv2v*

# Verify installations
RUN verilator --version && \
    yosys --version && \
    sby --help 2>&1 | head -1 && \
    sv2v --version

WORKDIR /work
CMD ["/bin/bash"]
