-- iPad/iPhone POS terminals (pos_app iOS build) register as their own platform.
ALTER TYPE "DevicePlatform" ADD VALUE IF NOT EXISTS 'ios';
