FROM ubuntu:22.04

ARG DM_VERSION=8.5.4

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Install TiUP
RUN curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh

# Add TiUP to PATH
ENV PATH="/root/.tiup/bin:${PATH}"
ENV DM_VERSION=${DM_VERSION}

# Expose ports
# TiDB: 4000, PD: 2379, DM-master: 8261
EXPOSE 4000 2379 8261

# Default command
# Use the container's real IP as the advertised host to avoid etcd/DM address mismatch.
CMD ["sh", "-c", "HOST=$(hostname -i); tiup playground v${DM_VERSION} --dm-master 1 --dm-worker 1 --tiflash 0 --without-monitor --host ${HOST}"]
