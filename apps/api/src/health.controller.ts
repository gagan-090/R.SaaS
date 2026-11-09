import { Controller, Get } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Public } from './common/decorators';
import { DbService } from './db/db.service';

@ApiTags('health')
@Controller('health')
export class HealthController {
  constructor(private db: DbService) {}

  @Public()
  @Get()
  async health() {
    await this.db.$queryRaw`SELECT 1`;
    // commit: which build is live (Render sets RENDER_GIT_COMMIT), so a fix can be checked from outside
    return { status: 'ok', time: new Date().toISOString(), commit: process.env.RENDER_GIT_COMMIT?.slice(0, 7) ?? null };
  }
}
