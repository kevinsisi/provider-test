FROM node:22-alpine

RUN npm config set strict-ssl false && npm install -g opencode-ai

WORKDIR /app

EXPOSE 4096

CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
