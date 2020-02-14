# k8s-snapshotter-audit setup:
FROM ubuntu:18.04

# Set up audit script:
RUN apt update
RUN apt -y install ruby-full curl gnupg2 apt-transport-https
COPY audit.rb /usr/bin/audit.rb
RUN chmod 0755 /usr/bin/audit.rb

# Install gcloud-sdk:
RUN echo "deb http://packages.cloud.google.com/apt cloud-sdk-bionic main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
# Yes, need to update again.
RUN apt update && apt install -y google-cloud-sdk
# Google Service Account with limited privileges.
COPY ./k8s_snapshotter_audit_sa.json /

# Set up kubectl:
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.13.2/bin/linux/amd64/kubectl
RUN chmod 755 /kubectl
RUN mv /kubectl /usr/bin/kubectl
RUN mkdir /root/.kube

# Latex to PDF software:
RUN apt-get -y install texlive

# Cheers!
