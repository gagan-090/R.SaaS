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
    return { status: 'ok', time: new Date().toISOString() };
  }
}
