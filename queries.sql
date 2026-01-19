-- ============================================
-- GSS Portfolio - Database Schema
-- Supabase PostgreSQL
-- ============================================

-- ============================================
-- TABLES
-- ============================================

-- Jobs table - управление задачами
CREATE TABLE public.jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'QUEUED',
    batch_id UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    
    CONSTRAINT valid_status CHECK (
        status IN ('QUEUED', 'PROCESSING', 'CLASSIFIED', 'FAILED', 'GENERATING', 'QC_REVIEW', 'MANUAL_REVIEW', 'COMPLETED', 'FATAL_ERROR')
    )
);

-- Renders table - результаты анализа изображений
CREATE TABLE public.renders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID REFERENCES public.jobs(id) ON DELETE CASCADE,
    source_image_url TEXT NOT NULL,
    detected_shot_type VARCHAR(100),
    confidence DECIMAL(5,4),
    generated_prompt TEXT,
    technical_tags JSONB DEFAULT '[]'::jsonb,
    motion_recommendation VARCHAR(50),
    full_analysis JSONB,
    processing_time_sec INTEGER,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Generation attempts table - попытки генерации для retry logic
CREATE TABLE public.generation_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    render_id UUID REFERENCES public.renders(id) ON DELETE CASCADE,
    attempt_number INTEGER NOT NULL DEFAULT 1,
    parameters JSONB DEFAULT '{"steps": 50, "sampler": "DPM++", "cfg_scale": 7.5, "structure_scale": 0.50}'::jsonb,
    qc_verdict VARCHAR(50),
    failure_reason TEXT,
    suggested_fix VARCHAR(100),
    nano_banana_response JSONB,
    created_at TIMESTAMPTZ DEFAULT now(),
    
    CONSTRAINT valid_attempt CHECK (attempt_number >= 1 AND attempt_number <= 5),
    CONSTRAINT valid_verdict CHECK (qc_verdict IS NULL OR qc_verdict IN ('PASS', 'FAIL'))
);

-- ============================================
-- INDEXES
-- ============================================

-- Jobs indexes
CREATE INDEX idx_jobs_status ON public.jobs(status);
CREATE INDEX idx_jobs_property_id ON public.jobs(property_id);
CREATE INDEX idx_jobs_created_at ON public.jobs(created_at DESC);

-- Renders indexes
CREATE INDEX idx_renders_job_id ON public.renders(job_id);
CREATE INDEX idx_renders_detected_shot_type ON public.renders(detected_shot_type);
CREATE INDEX idx_renders_technical_tags ON public.renders USING GIN(technical_tags);
CREATE INDEX idx_renders_created_at ON public.renders(created_at DESC);

-- Generation attempts indexes
CREATE INDEX idx_generation_attempts_render_id ON public.generation_attempts(render_id);
CREATE INDEX idx_generation_attempts_qc_verdict ON public.generation_attempts(qc_verdict);

-- ============================================
-- VIEWS
-- ============================================

-- Job statistics view
CREATE OR REPLACE VIEW public.v_jobs_stats AS
SELECT 
    status,
    COUNT(*) as count,
    MIN(created_at) as oldest,
    MAX(created_at) as newest
FROM public.jobs
GROUP BY status
ORDER BY count DESC;

-- Recent renders view
CREATE OR REPLACE VIEW public.v_recent_renders AS
SELECT 
    r.id,
    r.job_id,
    j.status as job_status,
    r.detected_shot_type,
    r.confidence,
    r.technical_tags,
    r.motion_recommendation,
    r.processing_time_sec,
    r.error_message,
    r.created_at
FROM public.renders r
JOIN public.jobs j ON r.job_id = j.id
ORDER BY r.created_at DESC
LIMIT 50;

-- Retry statistics view
CREATE OR REPLACE VIEW public.v_retry_stats AS
SELECT 
    r.id as render_id,
    r.detected_shot_type,
    COUNT(ga.id) as total_attempts,
    MAX(ga.attempt_number) as max_attempt,
    SUM(CASE WHEN ga.qc_verdict = 'PASS' THEN 1 ELSE 0 END) as passed,
    SUM(CASE WHEN ga.qc_verdict = 'FAIL' THEN 1 ELSE 0 END) as failed
FROM public.renders r
LEFT JOIN public.generation_attempts ga ON r.id = ga.render_id
GROUP BY r.id, r.detected_shot_type;

-- Recent attempts view
CREATE OR REPLACE VIEW public.v_recent_attempts AS
SELECT 
    ga.id,
    ga.render_id,
    ga.attempt_number,
    ga.parameters,
    ga.qc_verdict,
    ga.failure_reason,
    ga.suggested_fix,
    ga.created_at,
    r.detected_shot_type
FROM public.generation_attempts ga
JOIN public.renders r ON ga.render_id = r.id
ORDER BY ga.created_at DESC
LIMIT 50;

-- ============================================
-- EXAMPLE QUERIES
-- ============================================

-- Query renders by technical tag (JSONB)
-- SELECT * FROM renders WHERE technical_tags @> '["interior"]';

-- Query renders with specific shot type
-- SELECT * FROM renders WHERE detected_shot_type = 'interior_living_room';

-- Get failed jobs with error details
-- SELECT j.id, j.status, r.error_message, r.created_at
-- FROM jobs j
-- JOIN renders r ON j.id = r.job_id
-- WHERE j.status = 'FAILED' AND r.error_message IS NOT NULL;

-- Get retry history for a render
-- SELECT attempt_number, parameters, qc_verdict, failure_reason, suggested_fix
-- FROM generation_attempts
-- WHERE render_id = 'your-render-id'
-- ORDER BY attempt_number;

-- Calculate average processing time by shot type
-- SELECT 
--     detected_shot_type,
--     AVG(processing_time_sec) as avg_time,
--     COUNT(*) as count
-- FROM renders
-- WHERE processing_time_sec IS NOT NULL
-- GROUP BY detected_shot_type;

-- ============================================
-- TRIGGERS (optional - for updated_at)
-- ============================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER jobs_updated_at
    BEFORE UPDATE ON public.jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER renders_updated_at
    BEFORE UPDATE ON public.renders
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();
