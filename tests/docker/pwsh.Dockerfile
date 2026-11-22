# PowerShell 7.6 LTS with Pester 5, for the module's tests (MCR has no 7.6 image yet).
FROM debian:12-slim
ARG PWSH_VERSION=7.6.10
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libicu72 libssl3 less curl && rm -rf /var/lib/apt/lists/*
ADD https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz /tmp/pwsh.tgz
RUN mkdir -p /opt/microsoft/powershell/7 && tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell/7 && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh && rm /tmp/pwsh.tgz
RUN pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module Pester -RequiredVersion 5.7.1 -Scope AllUsers -Force"
WORKDIR /src
