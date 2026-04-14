FROM rockylinux/rockylinux:8

# Install basic dependencies
RUN yum install -y \
    curl \
    tar \
    tmux \
    rsync \
    which \
    python3.11 \
    python3.11-pip \
    findutils \
    bc \
    && yum clean all

# Install Google Cloud CLI the proper way for authentication
RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz && \
    tar -xf google-cloud-cli-linux-x86_64.tar.gz -C /usr/local && \
    /usr/local/google-cloud-sdk/install.sh --quiet --usage-reporting false --path-update false && \
    rm google-cloud-cli-linux-x86_64.tar.gz

# Add gcloud to PATH
ENV PATH="/usr/local/google-cloud-sdk/bin:${PATH}"

# Set working directory
WORKDIR /app

# The DRAGEN bin will be downloaded at runtime
# Set up PATH for DRAGEN (will be installed to /opt/dragen)
ENV PATH="/opt/dragen/bin:${PATH}"

# Copy the execution script
COPY run_dragen.sh /app/run_dragen.sh
RUN chmod +x /app/run_dragen.sh

# No ENTRYPOINT — Nextflow injects its own command script into the container.
# run_dragen.sh is invoked explicitly from modules/dragen/main.nf.