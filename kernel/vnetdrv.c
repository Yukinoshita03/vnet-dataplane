#include <linux/etherdevice.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/skbuff.h>

struct vnet_priv {
	struct napi_struct napi;
	struct rtnl_link_stats64 stats;
};

static int vnet_poll(struct napi_struct *napi, int budget)
{
	napi_complete_done(napi, 0);
	return 0;
}

static int vnet_open(struct net_device *dev)
{
	struct vnet_priv *priv = netdev_priv(dev);

	netif_start_queue(dev);
	napi_enable(&priv->napi);
	return 0;
}

static int vnet_stop(struct net_device *dev)
{
	struct vnet_priv *priv = netdev_priv(dev);

	napi_disable(&priv->napi);
	netif_stop_queue(dev);
	return 0;
}

static netdev_tx_t vnet_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
	struct vnet_priv *priv = netdev_priv(dev);

	priv->stats.tx_packets++;
	priv->stats.tx_bytes += skb->len;
	dev_kfree_skb(skb);
	return NETDEV_TX_OK;
}

static void vnet_get_stats64(struct net_device *dev,
			     struct rtnl_link_stats64 *stats)
{
	struct vnet_priv *priv = netdev_priv(dev);

	*stats = priv->stats;
}

static const struct net_device_ops vnet_netdev_ops = {
	.ndo_open = vnet_open,
	.ndo_stop = vnet_stop,
	.ndo_start_xmit = vnet_start_xmit,
	.ndo_get_stats64 = vnet_get_stats64,
};

static void vnet_setup(struct net_device *dev)
{
	ether_setup(dev);
	dev->netdev_ops = &vnet_netdev_ops;
	dev->flags |= IFF_NOARP;
	dev->features |= NETIF_F_HW_CSUM;
	dev->min_mtu = 68;
	dev->max_mtu = ETH_DATA_LEN;
	eth_hw_addr_random(dev);
}

static struct net_device *vnet_dev;

static int __init vnet_init(void)
{
	struct vnet_priv *priv;
	int ret;

	vnet_dev = alloc_netdev(sizeof(*priv), "vnet%d", NET_NAME_ENUM, vnet_setup);
	if (!vnet_dev)
		return -ENOMEM;

	priv = netdev_priv(vnet_dev);
	netif_napi_add(vnet_dev, &priv->napi, vnet_poll);

	ret = register_netdev(vnet_dev);
	if (ret) {
		netif_napi_del(&priv->napi);
		free_netdev(vnet_dev);
		return ret;
	}

	pr_info("vnetdrv: registered %s\n", vnet_dev->name);
	return 0;
}

static void __exit vnet_exit(void)
{
	struct vnet_priv *priv;

	if (!vnet_dev)
		return;

	priv = netdev_priv(vnet_dev);
	unregister_netdev(vnet_dev);
	netif_napi_del(&priv->napi);
	free_netdev(vnet_dev);
	pr_info("vnetdrv: unloaded\n");
}

module_init(vnet_init);
module_exit(vnet_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Yukinoshita03");
MODULE_DESCRIPTION("Bootstrap virtual NIC driver for vnet-dataplane");
