import React from "react";
import {
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
  Sequence,
  Img,
  staticFile,
} from "remotion";

const theme = {
  bg: "#141413",
  light: "#FAF9F5",
  terracotta: "#D97757",
  sage: "#788C5D",
  golden: "#F5C97A",
  nebiusGreen: "#00E599",
  tavilyBlue: "#4353FF",
};

export const ViewsShowcase: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        flex: 1,
        backgroundColor: theme.bg,
        color: theme.light,
        fontFamily: "'Newsreader', Georgia, serif",
        position: "relative",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        justifyContent: "space-between",
        padding: "60px 80px",
        overflow: "hidden",
      }}
    >
      {/* ── Top Header Watermark ── */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          zIndex: 10,
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <Img
            src={staticFile("icon.png")}
            style={{ width: 44, height: 44, borderRadius: 12 }}
          />
          <span
            style={{
              fontFamily: "'Cinzel', serif",
              letterSpacing: "0.25em",
              fontSize: 16,
              fontWeight: 600,
              textTransform: "uppercase",
            }}
          >
            VieWs
          </span>
          <span style={{ opacity: 0.3 }}>•</span>
          <span
            style={{
              fontFamily: "monospace",
              fontSize: 14,
              opacity: 0.6,
              letterSpacing: "0.1em",
            }}
          >
            NEBIUS TOKEN FACTORY × TAVILY AI SEARCH
          </span>
        </div>
      </div>

      {/* ── Main Dynamic Stage: Sequence Acts ── */}
      <div
        style={{
          flex: 1,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          zIndex: 10,
          gap: 60,
        }}
      >
        {/* Act 1: Philosophy (Frames 0 - 540 = 0s - 18s) */}
        <Sequence from={0} durationInFrames={540}>
          <ActScene
            tag="Emotional Synesthesia"
            tagColor={theme.terracotta}
            title="Weather is not a forecast.<br/><em style='color: #F5C97A'>It is a state of mind.</em>"
            body="Most weather apps tell you whether to carry an umbrella. VieWs invites you to describe how you feel, translating subjective introspections into living, breathing atmospheric simulations."
            hudText="Pure Human Emotion → Procedural Atmosphere"
            imageSrc={staticFile("preview_1.png")}
            glowColor="rgba(217, 119, 87, 0.25)"
          />
        </Sequence>

        {/* Act 2: Nebius Token Factory (Frames 540 - 1140 = 18s - 38s) */}
        <Sequence from={540} durationInFrames={600}>
          <ActScene
            tag="Nebius Token Factory"
            tagColor={theme.nebiusGreen}
            title="Poetry into Living Physics<br/><em style='color: #00E599'>in 1.1 Seconds</em>."
            body="Powered by NVIDIA Nemotron-3.5-Lightning on Nebius Token Factory. High-throughput inference maps emotional prose to physical precipitation, wind velocity, fog density, and WCAG-compliant color palettes."
            hudText="NVIDIA Nemotron-3.5-Lightning • Latency: 1.12s"
            imageSrc={staticFile("preview_2.png")}
            glowColor="rgba(0, 229, 153, 0.2)"
          />
        </Sequence>

        {/* Act 3: Tavily AI Search (Frames 1140 - 1740 = 38s - 58s) */}
        <Sequence from={1140} durationInFrames={600}>
          <ActScene
            tag="Tavily AI Search"
            tagColor={theme.tavilyBlue}
            title="Subjective Memory Meets<br/><em style='color: #4353FF'>Real-World Grounding</em>."
            body="When you reference a destination — 'i really miss napoli' or 'autumn in kyoto' — Tavily retrieves live atmospheric telemetry in under 400ms, blending real-time weather observations into the emotional prompt."
            hudText="Live Grounding: Napoli is 14°c, clear • 340ms"
            imageSrc={staticFile("preview_3.png")}
            glowColor="rgba(67, 83, 255, 0.25)"
          />
        </Sequence>

        {/* Act 4: Spatial Constellation (Frames 1740 - 2340 = 58s - 78s) */}
        <Sequence from={1740} durationInFrames={600}>
          <ActScene
            tag="Spatial Memory Cosmos"
            tagColor={theme.golden}
            title="A Galaxy of Memories,<br/><em style='color: #F5C97A'>Responsive & Boundless</em>."
            body="Experiences crystallize into an interactive orbital cosmos. Pan the universe with spring physics, fully modular across iPhone SE, Pro Max, split-view iPad, and foldable dual-screens."
            hudText="Geometry-Driven Canvas • 60 FPS Spring Pan"
            imageSrc={staticFile("preview_1.png")}
            glowColor="rgba(245, 201, 122, 0.2)"
          />
        </Sequence>

        {/* Act 5: Coda / Hackathon Track (Frames 2340 - 2700 = 78s - 90s) */}
        <Sequence from={2340} durationInFrames={360}>
          <ActScene
            tag="Nebius & Tavily Hackathon"
            tagColor={theme.light}
            title="VieWs.<br/><em style='color: #FAF9F5'>Atmosphere as Emotion.</em>"
            body="Best Apps & Agents Track • Best Use of Tavily Award. Built with native Swift 6 strict concurrency, SpriteKit particle physics, and 5-layer procedural DSP audio synthesis."
            hudText="Production Ready on iOS & iPadOS"
            imageSrc={staticFile("preview_2.png")}
            glowColor="rgba(250, 249, 245, 0.15)"
          />
        </Sequence>
      </div>

      {/* ── Bottom Caption / Narrative Transcript ── */}
      <div
        style={{
          borderTop: "1px solid rgba(255, 255, 255, 0.12)",
          paddingTop: 20,
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          fontFamily: "monospace",
          fontSize: 13,
          opacity: 0.65,
          zIndex: 10,
        }}
      >
        <span>VieWs — Ambient Generative Weather Atmosphere</span>
        <span>Track: Best Apps and Agents • $3,000 Best Use of Tavily</span>
      </div>
    </div>
  );
};

interface ActSceneProps {
  tag: string;
  tagColor: string;
  title: string;
  body: string;
  hudText: string;
  imageSrc: string;
  glowColor: string;
}

const ActScene: React.FC<ActSceneProps> = ({
  tag,
  tagColor,
  title,
  body,
  hudText,
  imageSrc,
  glowColor,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const entrance = spring({
    frame,
    fps,
    config: { damping: 14, stiffness: 80 },
  });

  const opacity = interpolate(frame, [0, 20], [0, 1], {
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        flex: 1,
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        width: "100%",
        opacity,
      }}
    >
      {/* Narrative Typography */}
      <div
        style={{
          maxWidth: 680,
          transform: `translateY(${interpolate(entrance, [0, 1], [30, 0])}px)`,
        }}
      >
        <div
          style={{
            fontFamily: "monospace",
            fontSize: 15,
            letterSpacing: "0.2em",
            textTransform: "uppercase",
            color: tagColor,
            marginBottom: 16,
          }}
        >
          {tag}
        </div>
        <h1
          style={{
            fontSize: 56,
            fontWeight: 300,
            lineHeight: 1.15,
            marginBottom: 24,
            letterSpacing: "-0.02em",
          }}
          dangerouslySetInnerHTML={{ __html: title }}
        />
        <p
          style={{
            fontSize: 22,
            lineHeight: 1.6,
            opacity: 0.75,
            marginBottom: 32,
            fontWeight: 300,
          }}
        >
          {body}
        </p>

        {/* Technical HUD Pill */}
        <div
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 12,
            padding: "10px 18px",
            borderRadius: 30,
            background: "rgba(255, 255, 255, 0.05)",
            border: "1px solid rgba(255, 255, 255, 0.12)",
            fontFamily: "monospace",
            fontSize: 13,
            color: "#FAF9F5",
          }}
        >
          <span
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              backgroundColor: tagColor,
            }}
          />
          {hudText}
        </div>
      </div>

      {/* Floating 3D Device Mockup */}
      <div
        style={{
          position: "relative",
          width: 380,
          height: 640,
          transform: `perspective(1000px) rotateY(${interpolate(
            frame,
            [0, 300],
            [-6, 6]
          )}deg) translateY(${interpolate(entrance, [0, 1], [40, 0])}px)`,
          transition: "transform 0.1s linear",
        }}
      >
        {/* Ambient Backlight Glow */}
        <div
          style={{
            position: "absolute",
            inset: -40,
            background: glowColor,
            filter: "blur(60px)",
            borderRadius: "50%",
            zIndex: 0,
          }}
        />

        {/* iPhone Bezel */}
        <div
          style={{
            position: "relative",
            width: "100%",
            height: "100%",
            backgroundColor: "#0d0d12",
            borderRadius: 56,
            border: "2px solid rgba(255, 255, 255, 0.2)",
            padding: 12,
            boxShadow: "0 30px 80px rgba(0, 0, 0, 0.8)",
            zIndex: 1,
            overflow: "hidden",
          }}
        >
          {/* Dynamic Island */}
          <div
            style={{
              position: "absolute",
              top: 18,
              left: "50%",
              transform: "translateX(-50%)",
              width: 100,
              height: 28,
              backgroundColor: "#000",
              borderRadius: 20,
              zIndex: 10,
            }}
          />
          {/* Screenshot Image */}
          <Img
            src={imageSrc}
            style={{
              width: "100%",
              height: "100%",
              objectFit: "cover",
              borderRadius: 44,
            }}
          />
        </div>
      </div>
    </div>
  );
};
