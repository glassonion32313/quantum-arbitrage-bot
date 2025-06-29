#!/bin/bash
# Vast.ai setup script
echo "🚀 Setting up Quantum Arbitrage Bot on Vast.ai..."

# Update system
apt-get update && apt-get upgrade -y

# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs git python3 build-essential

# Install PM2
npm install -g pm2

# Clone repository
git clone https://github.com/your-username/quantum-arbitrage-bot.git
cd quantum-arbitrage-bot

# Install dependencies
npm install

# Copy environment file
cp .env.example .env
echo "⚠️  Edit .env file with your actual keys"

# Create startup script
cat > start.sh << EOL
#!/bin/bash
pm2 start quantum-engine.js --name quantum-bot
pm2 logs quantum-bot
EOL

chmod +x start.sh

echo "✅ Setup complete! Edit .env then run ./start.sh"
