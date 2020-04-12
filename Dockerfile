FROM mcr.microsoft.com/powershell:lts-ubuntu-18.04

LABEL maintainer="Xorima"
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.name="xorima/github-cookstyle-runner"
LABEL org.label-schema.description="A cookstyle runner system for Github Repositories"
LABEL org.label-schema.url="https://github.com/Xorima/github-cookstyle-runner"
LABEL org.label-schema.vcs-url="https://github.com/Xorima/github-cookstyle-runner"
RUN apt-get update && apt-get install -y git
COPY app /app

ENTRYPOINT ["pwsh", "-file", "app/entrypoint.ps1"]
