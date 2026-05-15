FROM node:20-bookworm

# Dart + Python + ffmpeg (para resolver y stems)
RUN apt-get update && apt-get install -y \
    curl unzip xz-utils python3 python3-pip ffmpeg ca-certificates gnupg \
 && curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/dart.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/dart.gpg] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main" > /etc/apt/sources.list.d/dart_stable.list \
 && apt-get update && apt-get install -y dart \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm install

COPY . .
RUN dart pub get --directory dart_resolver

ENV PORT=8080
EXPOSE 8080
CMD ["npm", "start"]
