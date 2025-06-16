FROM jenkins/jenkins:jdk21

LABEL MAINTAINER="indivirtuell <office@indivirtuell.net>"

USER root

RUN apt --allow-releaseinfo-change-suite update

RUN apt install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common chromium rsync gettext-base xvfb jq

RUN apt dist-upgrade -y

RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
RUN mv kubectl /usr/local/bin/kubectl
RUN chmod +x /usr/local/bin/kubectl

RUN curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y
RUN echo 'source $HOME/.cargo/env' >> $HOME/.bashrc

RUN groupadd -g 988 docker

RUN usermod -aG docker jenkins

ENV CHROME_BIN /usr/bin/chromium

USER jenkins
