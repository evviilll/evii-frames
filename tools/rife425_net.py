"""RIFE 4.25 inference graph. Architecture matches Practical-RIFE train_log (MIT, hzwer)."""
import torch
import torch.nn as nn
import torch.nn.functional as F


def resize_bilinear(x, scale_factor):
    """Match F.interpolate bilinear with align_corners=False.

    Core ML's upsample_bilinear does not. A fixed-shape trace of that op was
    0.197 mean-abs away from PyTorch at t=0.5 on CPU, GPU, and the Neural
    Engine, while t=0 still looked fine because the flow is ~0 there.
    grid_sample with this source grid matches interpolate to 1e-6 and lowers
    to a resample op.
    """
    n, _, h, w = x.shape
    oh = int(h * scale_factor)
    ow = int(w * scale_factor)
    dtype = x.dtype
    device = x.device
    dst_y = torch.arange(oh, device=device, dtype=dtype)
    dst_x = torch.arange(ow, device=device, dtype=dtype)
    src_y = (dst_y + 0.5) / float(scale_factor) - 0.5
    src_x = (dst_x + 0.5) / float(scale_factor) - 0.5
    # align_corners=False unnormalize: g = (2*src + 1)/size - 1
    gy = (src_y * 2.0 + 1.0) / float(h) - 1.0
    gx = (src_x * 2.0 + 1.0) / float(w) - 1.0
    grid_y = gy.view(1, oh, 1).expand(n, oh, ow)
    grid_x = gx.view(1, 1, ow).expand(n, oh, ow)
    sampling_grid = torch.stack((grid_x, grid_y), 3)
    return F.grid_sample(
        x,
        sampling_grid,
        mode="bilinear",
        padding_mode="border",
        align_corners=False,
    )


def warp(tenInput, tenFlow):
    b, _, h, w = tenFlow.shape
    device = tenFlow.device
    dtype = tenFlow.dtype
    xs = torch.linspace(-1.0, 1.0, w, device=device, dtype=dtype)
    ys = torch.linspace(-1.0, 1.0, h, device=device, dtype=dtype)
    grid_x = xs.view(1, 1, 1, w).expand(b, 1, h, w)
    grid_y = ys.view(1, 1, h, 1).expand(b, 1, h, w)
    base = torch.cat([grid_x, grid_y], 1)
    tenFlow = torch.cat(
        [
            tenFlow[:, 0:1] / ((tenInput.shape[3] - 1.0) / 2.0),
            tenFlow[:, 1:2] / ((tenInput.shape[2] - 1.0) / 2.0),
        ],
        1,
    )
    g = (base + tenFlow).permute(0, 2, 3, 1)
    return F.grid_sample(
        tenInput, g, mode="bilinear", padding_mode="border", align_corners=True
    )


def conv(in_planes, out_planes, kernel_size=3, stride=1, padding=1, dilation=1):
    return nn.Sequential(
        nn.Conv2d(
            in_planes,
            out_planes,
            kernel_size=kernel_size,
            stride=stride,
            padding=padding,
            dilation=dilation,
            bias=True,
        ),
        nn.LeakyReLU(0.2, inplace=False),
    )


class Head(nn.Module):
    def __init__(self):
        super().__init__()
        self.cnn0 = nn.Conv2d(3, 16, 3, 2, 1)
        self.cnn1 = nn.Conv2d(16, 16, 3, 1, 1)
        self.cnn2 = nn.Conv2d(16, 16, 3, 1, 1)
        self.cnn3 = nn.ConvTranspose2d(16, 4, 4, 2, 1)
        self.relu = nn.LeakyReLU(0.2, inplace=False)

    def forward(self, x):
        x0 = self.cnn0(x)
        x = self.relu(x0)
        x1 = self.cnn1(x)
        x = self.relu(x1)
        x2 = self.cnn2(x)
        x = self.relu(x2)
        return self.cnn3(x)


class ResConv(nn.Module):
    def __init__(self, c, dilation=1):
        super().__init__()
        self.conv = nn.Conv2d(c, c, 3, 1, dilation, dilation=dilation)
        self.beta = nn.Parameter(torch.ones((1, c, 1, 1)))
        self.relu = nn.LeakyReLU(0.2, inplace=False)

    def forward(self, x):
        return self.relu(self.conv(x) * self.beta + x)


class IFBlock(nn.Module):
    def __init__(self, in_planes, c=64):
        super().__init__()
        self.conv0 = nn.Sequential(
            conv(in_planes, c // 2, 3, 2, 1),
            conv(c // 2, c, 3, 2, 1),
        )
        self.convblock = nn.Sequential(*[ResConv(c) for _ in range(8)])
        self.lastconv = nn.Sequential(
            nn.ConvTranspose2d(c, 4 * 13, 4, 2, 1),
            nn.PixelShuffle(2),
        )

    def forward(self, x, flow, scale):
        x = resize_bilinear(x, 1.0 / scale)
        if flow is not None:
            flow = resize_bilinear(flow, 1.0 / scale) * (1.0 / scale)
            x = torch.cat((x, flow), 1)
        feat = self.convblock(self.conv0(x))
        tmp = self.lastconv(feat)
        tmp = resize_bilinear(tmp, scale)
        flow = tmp[:, :4] * scale
        mask = tmp[:, 4:5]
        feat = tmp[:, 5:]
        return flow, mask, feat


class IFNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.block0 = IFBlock(7 + 8, c=192)
        self.block1 = IFBlock(8 + 4 + 8 + 8, c=128)
        self.block2 = IFBlock(8 + 4 + 8 + 8, c=96)
        self.block3 = IFBlock(8 + 4 + 8 + 8, c=64)
        self.block4 = IFBlock(8 + 4 + 8 + 8, c=32)
        self.encode = Head()

    def forward(self, img0, img1, timestep, scale_list):
        # timestep: N,1,1,1
        timestep = timestep.repeat(1, 1, img0.shape[2], img0.shape[3])
        f0 = self.encode(img0)
        f1 = self.encode(img1)
        flow = None
        mask = None
        feat = None
        warped_img0 = img0
        warped_img1 = img1
        blocks = (self.block0, self.block1, self.block2, self.block3, self.block4)
        for i, block in enumerate(blocks):
            scale = scale_list[i]
            if flow is None:
                flow, mask, feat = block(
                    torch.cat((img0, img1, f0, f1, timestep), 1), None, scale
                )
            else:
                wf0 = warp(f0, flow[:, :2])
                wf1 = warp(f1, flow[:, 2:4])
                fd, mask, feat = block(
                    torch.cat((warped_img0, warped_img1, wf0, wf1, timestep, mask, feat), 1),
                    flow,
                    scale,
                )
                flow = flow + fd
            warped_img0 = warp(img0, flow[:, :2])
            warped_img1 = warp(img1, flow[:, 2:4])
        mask = torch.sigmoid(mask)
        return warped_img0 * mask + warped_img1 * (1 - mask)


class RIFE425(nn.Module):
    def __init__(self, uhd=False):
        super().__init__()
        self.net = IFNet()
        # Python floats so scale_factor stays a constant in the graph.
        if uhd:
            self.scale_list = (32.0, 16.0, 8.0, 4.0, 2.0)
        else:
            self.scale_list = (16.0, 8.0, 4.0, 2.0, 1.0)

    def forward(self, img0, img1, timestep):
        return self.net(img0, img1, timestep, self.scale_list)
