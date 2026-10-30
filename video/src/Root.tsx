import React from "react";
import { Composition } from "remotion";
import { ViewsShowcase } from "./ViewsShowcase";

export const Root: React.FC = () => {
  return (
    <>
      <Composition
        id="ViewsShowcase"
        component={ViewsShowcase}
        durationInFrames={30 * 90} // 90 seconds @ 30fps (or 60fps * 90 = 5400)
        fps={30}
        width={1920}
        height={1080}
      />
    </>
  );
};
